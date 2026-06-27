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

    CAP = 5_000          # cap the pending count; beyond it we just pick max_interval
    FACTOR = 0.06        # seconds of delay per pending child
    REKICK_AFTER = 5.minutes
    REKICK_BATCH = 200   # bound per-run rekicks; later polls handle the rest

    def perform(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval, token = nil)
      raise ArgumentError, "branch_log_ids must not be empty" if branch_log_ids.empty?

      # Fencing: every merge_branches pass mints a fresh token and writes it onto
      # the branch logs, so a poller from a superseded chain (parent replay /
      # re-enqueue) holds a stale token. It stops quietly — no poll, no wake, no
      # reschedule — leaving only the newest chain to drive the merge. (A nil token
      # is a pre-upgrade job enqueued before fencing existed; it runs unfenced.)
      return if superseded?(branch_log_ids, token)

      # Per-branch probe (kept as maps so we can persist each branch's own state,
      # not just the merge aggregate). Same query count as a plain sum/all?.
      pending_by_branch = branch_log_ids.to_h { |id| [id, BranchProbe.incomplete(id).limit(CAP).count] }
      sealed_by_branch = branch_log_ids.to_h { |id| [id, BranchProbe.sealed?(id)] }
      pending = pending_by_branch.values.sum
      sealed = sealed_by_branch.values.all?

      if sealed && pending.zero?
        record_poll!(pending_by_branch, sealed_by_branch, token, next_poll_at: nil)
        parent_job_class.constantize.perform_later(parent_key)
        return
      end

      rekick_dropped_jobs(branch_log_ids)

      delay = (pending * FACTOR).clamp(min_interval, max_interval)
      record_poll!(pending_by_branch, sealed_by_branch, token, next_poll_at: delay.seconds.from_now)
      self.class.set(wait: delay.seconds)
        .perform_later(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval, token)
    end

    private

    # A poller is superseded when its token no longer matches what's stored on the
    # branch logs (a newer merge_branches pass rotated it). A plain read is enough
    # for the early-out; the persisting write in record_poll! re-checks the token
    # under a row lock so it can never clobber the newer chain.
    def superseded?(branch_log_ids, token)
      logs = ExecutionLog.where(id: branch_log_ids).to_a
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
    def record_poll!(pending_by_branch, sealed_by_branch, token, next_poll_at:)
      now = Time.current
      ExecutionLog.where(id: pending_by_branch.keys).find_each do |log|
        # Lock the row so this read-modify-write can't clobber a concurrent token
        # rotation (merge_branches) or another poller's metadata write — both touch
        # the same JSON column. Re-check the token under the lock and skip if we've
        # been superseded mid-run, so a stale poller never overwrites the fence.
        log.with_lock do
          meta = log.metadata || {}
          next unless meta["poll_token"] == token
          meta["poll"] = {
            "last_polled_at" => now.iso8601,
            "next_poll_at" => next_poll_at&.iso8601,
            "pending" => pending_by_branch[log.id],
            "sealed" => sealed_by_branch[log.id],
            "polls" => meta.dig("poll", "polls").to_i + 1
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
    def rekick_dropped_jobs(branch_log_ids)
      branch_log_ids.each do |id|
        Workflow.where(parent_execution_log_id: id, state: Workflow.states[:idle], started_at: nil)
          .where("updated_at < ?", REKICK_AFTER.ago)
          .limit(REKICK_BATCH)
          .find_each do |child|
            # Intentionally uses the GUARDED perform_later (single-child path),
            # unlike the bulk perform_all_later bypass in dispatch_children.
            child.job_klass.perform_later(child.key, **child.kwargs.symbolize_keys)
          end
      end
    end
  end
end
