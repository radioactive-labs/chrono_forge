# frozen_string_literal: true

module ChronoForge
  # Lightweight poller that joins one or more branches. NOT a workflow — it holds
  # no lock, does no replay, and carries no context. It exists so the heavy parent
  # workflow is replayed only twice per merge (kick off + completion wake).
  class BranchMergeJob < ActiveJob::Base
    CAP = 5_000          # cap the pending count; beyond it we just pick max_interval
    FACTOR = 0.06        # seconds of delay per pending child
    REKICK_AFTER = 5.minutes
    REKICK_BATCH = 200   # bound per-run rekicks; later polls handle the rest

    def perform(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval)
      raise ArgumentError, "branch_log_ids must not be empty" if branch_log_ids.empty?

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

    # Anything not :completed counts as incomplete (Option A): failed/stalled
    # children intentionally keep the parent parked until the user recovers them.
    def incomplete_scope(branch_log_id)
      Workflow.where(parent_execution_log_id: branch_log_id)
        .where.not(state: Workflow.states[:completed])
    end

    def branch_sealed?(branch_log_id)
      ExecutionLog.where(id: branch_log_id, state: ExecutionLog.states[:completed]).exists?
    end

    # A child that was dispatched but never picked up (its job was dropped by the
    # backend) sits in :idle forever — note branch children keep started_at nil
    # their whole life (the executor only sets started_at when it CREATES the row,
    # but branch children are pre-inserted), so :idle, not started_at, is the
    # "never ran" signal. We only re-kick :idle children idle past REKICK_AFTER
    # (a running child must never be re-dispatched; a failed/stalled child needs
    # operator recovery). Re-enqueue of an :idle child a worker just grabbed is
    # still safe — the lock guard rejects the duplicate. Capped per run.
    def rekick_dropped_jobs(branch_log_ids)
      branch_log_ids.each do |id|
        Workflow.where(parent_execution_log_id: id, state: Workflow.states[:idle])
          .where("updated_at < ?", REKICK_AFTER.ago)
          .limit(REKICK_BATCH)
          .find_each do |child|
            child.job_klass.perform_later(child.key, **child.kwargs.symbolize_keys)
          end
      end
    end
  end
end
