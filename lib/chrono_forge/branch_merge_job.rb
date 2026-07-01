# frozen_string_literal: true

module ChronoForge
  # Lightweight poller that joins one or more branches. NOT a workflow — it holds
  # no lock, does no replay, and carries no context. It exists so the heavy parent
  # workflow is replayed only twice per merge (kick off + completion wake).
  class BranchMergeJob < ActiveJob::Base
    # The poller is the parent's only wake mechanism, so survive TRANSIENT
    # infrastructure errors (DB connection/timeout/deadlock) with backoff. Any
    # other error — a programming bug, a bad guard — is NOT retried: it propagates
    # to the backend's failed-job queue where it's visible, rather than being
    # silently retried-then-discarded (which would orphan the parent in :idle).
    retry_on ActiveRecord::ConnectionNotEstablished,
      ActiveRecord::ConnectionTimeoutError,
      ActiveRecord::Deadlocked,
      ActiveRecord::LockWaitTimeout,
      wait: :polynomially_longer, attempts: 25

    ETA_FRACTION = 0.5   # poll at this fraction of the projected time-to-drain
    REKICK_AFTER = 5.minutes
    REKICK_BATCH = 200   # bound per-run rekicks; later polls handle the rest

    def perform(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval, token = nil)
      raise ArgumentError, "branch_log_ids must not be empty" if branch_log_ids.empty?

      # Fencing: every merge_branches pass mints a fresh token and writes it onto
      # the branch logs, so a poller from a superseded chain (parent replay /
      # re-enqueue) holds a stale token. It stops quietly — no poll, no wake, no
      # reschedule — leaving only the newest chain to drive the merge. (A nil token
      # is a pre-upgrade job enqueued before fencing existed; it runs unfenced.)
      logs = ExecutionLog.where(id: branch_log_ids).to_a
      return if superseded?(logs, token)

      # Per-branch probe (kept as maps so we can persist each branch's own state,
      # not just the merge aggregate). Same query count as a plain sum/all?.
      # The pending count is UNCAPPED: it feeds the drain signal below (a change in
      # pending since the prior poll), which a CAP would flatten into a false
      # "not draining" for large branches.
      prev_pending_by_branch = logs.to_h { |l| [l.id, l.metadata&.dig("poll", "pending")] }
      pending_by_branch = branch_log_ids.to_h { |id| [id, BranchProbe.incomplete(id).count] }
      sealed_by_branch = branch_log_ids.to_h { |id| [id, BranchProbe.sealed?(id)] }
      pending = pending_by_branch.values.sum
      sealed = sealed_by_branch.values.all?

      if sealed && pending.zero?
        record_poll!(pending_by_branch, sealed_by_branch, token,
          next_poll_at: nil, interval: nil, rate_by_branch: {}, rekicked_by_branch: {})
        parent_job_class.constantize.perform_later(parent_key)
        return
      end

      rekicked_by_branch = rekick_dropped_jobs(branch_log_ids, pending_by_branch, prev_pending_by_branch)

      # Cadence is driven by ESTIMATED TIME-TO-DRAIN, measured from the prior
      # poll's persisted pending. `motion` (EXISTS probes) is the fallback signal
      # when nothing completed this interval: :running => a live worker is
      # executing a child (hold the floor, it'll finish); :dispatched => the only
      # motion is a queued/rekicked-but-unpicked child (back off exponentially,
      # it may never be picked up); :none => blocked/waiting (max backstop).
      # See reschedule_delay. Computed lazily below, only off the drain path.
      prior = logs.map { |l| l.metadata&.dig("poll") }
      # Only trust the AGGREGATE prev_pending when every requested branch log is
      # loaded AND carries a prior sample — otherwise `pending` (over all
      # branch_log_ids) and prev_pending (over loaded logs) would cover different
      # sets and yield a bogus aggregate rate. Missing/partial => no sample =>
      # bootstrap. Per-branch rate below is independently safe (missing => nil => 0).
      complete_prior = logs.size == branch_log_ids.size && prior.all?
      prev_pending = (prior.sum { |p| p["pending"].to_i } if complete_prior)
      prev_polled_at = prior.filter_map { |p| p && p["last_polled_at"] }.map { |s| Time.zone.parse(s) }.min
      elapsed = prev_polled_at && (Time.current - prev_polled_at)
      prev_delay = prior.filter_map { |p| p && p["interval"] }.max

      # Drain rate = children completed / second since the prior poll — THIS is the
      # throughput surfaced on the dashboard. Per branch for display; aggregated for
      # the ETA. Zero unless the branch actually drained (a no-headway / cold poll).
      # NOTE: the aggregate ETA blurs a heterogeneous multi-branch merge; acceptable
      # (the common case is single-branch; clamp + per-poll re-estimate bound any
      # skew, and only poll timing is affected — the parent is still woken).
      drained = ->(pend, prev) { prev && elapsed && elapsed > 0 && pend < prev }
      rate_by_branch = pending_by_branch.to_h do |id, pend|
        prev = prev_pending_by_branch[id]
        [id, drained.call(pend, prev) ? (prev - pend) / elapsed.to_f : 0.0]
      end
      rate = drained.call(pending, prev_pending) ? (prev_pending - pending) / elapsed.to_f : 0.0

      # Only needed when the ETA branch won't be taken (rate == 0); computing the
      # EXISTS probes lazily keeps them off the hot drain path. See reschedule_delay.
      motion = if rate > 0 then nil
      elsif branch_log_ids.any? { |id| BranchProbe.running?(id) } then :running
      elsif branch_log_ids.any? { |id| BranchProbe.dispatched?(id) } then :dispatched
      else :none
      end

      delay = reschedule_delay(pending, rate, motion, prev_delay, min_interval, max_interval)
      record_poll!(pending_by_branch, sealed_by_branch, token, next_poll_at: delay.seconds.from_now,
        interval: delay, rate_by_branch: rate_by_branch, rekicked_by_branch: rekicked_by_branch)
      self.class.set(wait: delay.seconds)
        .perform_later(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval, token)
    end

    private

    # Adaptive poll cadence driven by ESTIMATED TIME-TO-DRAIN, not backlog size.
    # When the branch-set drained since the last poll we project completion from
    # the measured rate and poll at ETA_FRACTION of it, clamped [min, max]. Because
    # each poll re-estimates against the shrinking remainder, cadence converges
    # geometrically and detects the merge within ~min_interval of the last child
    # finishing — where the old count-based cadence polled SLOWEST (max_interval)
    # exactly when a fast-draining backlog was about to complete.
    #
    # No completion observed this interval — fall back on `motion`:
    #   :running    => a live worker is executing a child; it will finish, so hold
    #                  the responsive floor (matches prior behaviour and avoids
    #                  waking the parent late for a slow/low-fan-out child).
    #   :dispatched => the only motion is a queued/rekicked-but-unpicked child that
    #                  may never be picked up => exponential backoff from the floor
    #                  (double prev_delay, capped at max), catching a quick recovery
    #                  within seconds without spinning on a dead dispatch.
    #   :none       => nothing can progress (blocked/failed or parked on a wait) =>
    #                  straight to max_interval, the cheap recovery backstop.
    # min_interval <= max_interval is enforced in merge_branches, so clamp is safe.
    # `rate` is children/s measured by the caller (0 => nothing completed since the
    # prior poll / cold poll).
    def reschedule_delay(pending, rate, motion, prev_delay, min_interval, max_interval)
      return (pending / rate * ETA_FRACTION).clamp(min_interval, max_interval) if rate > 0

      case motion
      when :running then min_interval
      when :dispatched then prev_delay ? (prev_delay * 2).clamp(min_interval, max_interval) : min_interval
      else max_interval
      end
    end

    # A poller is superseded when its token no longer matches what's stored on the
    # branch logs (a newer merge_branches pass rotated it). A plain read is enough
    # for the early-out; the persisting write in record_poll! re-checks the token
    # under a row lock so it can never clobber the newer chain.
    def superseded?(logs, token)
      logs.empty? || logs.any? { |log| log.metadata&.dig("poll_token") != token }
    end

    # ActiveJob exposes no portable API to enumerate enqueued/scheduled jobs, so a
    # poller in the backend's scheduled set is invisible to a backend-agnostic
    # dashboard. We make the durable log the source of truth instead: each poll
    # stamps its observable state onto every target branch log's metadata, so the
    # dashboard can list in-flight merges (and a next_poll_at long in the past with
    # work still pending is the signal that the poller was dropped). This is purely
    # observational — replay and correctness never read it. It writes a "poll"
    # sub-key, leaving spawn_each's "cursors" metadata untouched.
    def record_poll!(pending_by_branch, sealed_by_branch, token, next_poll_at:, interval:, rate_by_branch:, rekicked_by_branch:)
      now = Time.current
      ExecutionLog.where(id: pending_by_branch.keys).find_each do |log|
        # Lock the row so this read-modify-write can't clobber a concurrent token
        # rotation (merge_branches) or another poller's metadata write — both touch
        # the same JSON column. Re-check the token under the lock and skip if we've
        # been superseded mid-run, so a stale poller never overwrites the fence.
        log.with_lock do
          meta = log.metadata || {}
          next unless meta["poll_token"] == token
          prev = meta["poll"] || {}
          n = rekicked_by_branch[log.id].to_i
          pend = pending_by_branch[log.id]
          rate = rate_by_branch[log.id].to_f
          meta["poll"] = {
            "last_polled_at" => now.iso8601,
            "next_poll_at" => next_poll_at&.iso8601,
            "interval" => interval,
            "pending" => pend,
            "sealed" => sealed_by_branch[log.id],
            "rate" => rate.round(2),                               # children/s (throughput)
            "eta_seconds" => (rate > 0 ? (pend / rate).round : nil),
            "polls" => prev["polls"].to_i + 1,
            "rekicked" => n,
            "rekick_total" => prev["rekick_total"].to_i + n,
            "last_rekick_at" => (n.positive? ? now.iso8601 : prev["last_rekick_at"])
          }
          log.update!(metadata: meta)
        end
      end
    end

    # A child that was dispatched but never picked up (its job was dropped by the
    # backend) sits :idle with started_at nil. setup_workflow! stamps started_at
    # on a child's first execution, so a nil started_at precisely means "never
    # ran" — that's what we rekick on. It correctly excludes a child that ran and
    # is now parked on a wait/wait_until (also :idle, but started_at is set):
    # rekicking that would re-evaluate the wait condition prematurely and pile up
    # duplicate scheduled jobs. We also require the row to be stale past
    # REKICK_AFTER (a freshly dispatched child just hasn't been grabbed yet) and
    # keep the :idle guard (a running/failed/stalled child must never be
    # re-dispatched). Re-enqueue of an :idle child a worker just grabbed is still
    # safe — the lock guard rejects the duplicate. Capped per run.
    def rekick_dropped_jobs(branch_log_ids, pending_by_branch, prev_pending_by_branch)
      cutoff = REKICK_AFTER.ago
      branch_log_ids.to_h do |id|
        # Skip a branch that drained since its last poll: its pending dropped, so
        # the queue is moving and idle never-started children are just in line,
        # not dropped. With no prior sample (cold poll) we don't gate — the
        # per-child staleness filter below still spares freshly-dispatched rows.
        prev = prev_pending_by_branch[id]
        next [id, 0] if prev && pending_by_branch[id] < prev

        count = 0
        Workflow.where(parent_execution_log_id: id, state: Workflow.states[:idle], started_at: nil)
          .where("updated_at < ?", cutoff)
          .limit(REKICK_BATCH)
          .find_each do |child|
            # Intentionally uses the GUARDED perform_later (single-child path),
            # unlike the bulk perform_all_later bypass in dispatch_children.
            #
            # Rekick is best-effort recovery, so one bad child must never sink the
            # poll: a raise here (e.g. cross-version kwarg drift failing the enqueue
            # guard) would abort the whole run and — since it isn't a transient AR
            # error — dead-letter the poller, orphaning every healthy sibling. Catch
            # per child, log, and let the next poll retry it (it's still idle+stale).
            child.job_klass.perform_later(child.key, **child.kwargs.symbolize_keys)
            # Debounce: bump updated_at so this child isn't re-rekicked until it's
            # been unstarted for another REKICK_AFTER — one redelivery window for a
            # worker to pick it up. Only on a SUCCESSFUL enqueue; a rescued failure
            # leaves it stale so the next poll retries.
            child.touch
            count += 1
          rescue => e
            Rails.logger.error do
              "ChronoForge:BranchMergeJob rekick failed for child #{child.key}: " \
              "#{e.class}: #{e.message}"
            end
          end
        [id, count]
      end
    end
  end
end
