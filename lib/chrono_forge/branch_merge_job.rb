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

    def perform(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval)
      raise ArgumentError, "branch_log_ids must not be empty" if branch_log_ids.empty?

      pending = branch_log_ids.sum { |id| BranchProbe.incomplete(id).limit(CAP).count }
      sealed = branch_log_ids.all? { |id| BranchProbe.sealed?(id) }

      if sealed && pending.zero?
        parent_job_class.constantize.perform_later(parent_key)
        return
      end

      rekick_dropped_jobs(branch_log_ids)

      delay = [[pending * FACTOR, min_interval].max, max_interval].min
      self.class.set(wait: delay.seconds)
        .perform_later(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval)
    end

    private

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
