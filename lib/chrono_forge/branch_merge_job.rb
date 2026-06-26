# frozen_string_literal: true

module ChronoForge
  # Lightweight poller that joins one or more branches. NOT a workflow — it holds
  # no lock, does no replay, and carries no context. It exists so the heavy parent
  # workflow is replayed only twice per merge (kick off + completion wake).
  class BranchMergeJob < ActiveJob::Base
    CAP = 5_000          # cap the pending count; beyond it we just pick max_interval
    FACTOR = 0.06        # seconds of delay per pending child
    REKICK_AFTER = 5.minutes

    def perform(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval)
      pending = branch_log_ids.sum { |id| incomplete_scope(id).limit(CAP).count }
      sealed = branch_log_ids.all? { |id| branch_sealed?(id) }

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

    def incomplete_scope(branch_log_id)
      Workflow.where(parent_execution_log_id: branch_log_id)
        .where.not(state: Workflow.states[:completed])
    end

    def branch_sealed?(branch_log_id)
      ExecutionLog.where(id: branch_log_id, state: ExecutionLog.states[:completed]).exists?
    end

    # A child dispatched but never run (its job was dropped by the backend) is
    # re-enqueued. started_at IS NULL can't distinguish "never enqueued" from
    # "queued but not yet picked up", so we only re-kick children that have been
    # idle past REKICK_AFTER. Re-enqueue is idempotent: a completed/running child
    # no-ops via the executable?/lock guard.
    def rekick_dropped_jobs(branch_log_ids)
      branch_log_ids.each do |id|
        Workflow.where(parent_execution_log_id: id, started_at: nil)
          .where("updated_at < ?", REKICK_AFTER.ago)
          .find_each do |child|
            child.job_klass.perform_later(child.key, **child.kwargs.symbolize_keys)
          end
      end
    end
  end
end
