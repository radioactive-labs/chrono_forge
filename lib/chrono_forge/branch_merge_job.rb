# frozen_string_literal: true

module ChronoForge
  # Lightweight poller that joins one or more branches. NOT a workflow — it holds
  # no lock, does no replay, and carries no context. It exists so the heavy parent
  # workflow is replayed only twice per merge (kick off + completion wake).
  class BranchMergeJob < ActiveJob::Base
    # The poller is the SOLE wake mechanism for a parked merge — a transient error
    # (DB blip, etc.) before the reschedule below would otherwise orphan the parent
    # in :idle (indistinguishable from never-started, invisible to recovery scans).
    # Retry transient failures with backoff so the poll chain survives.
    retry_on StandardError, wait: :polynomially_longer, attempts: 25
    # An empty branch_log_ids is a caller bug, not a transient fault — don't retry it.
    # MUST be declared AFTER retry_on: ActiveSupport::Rescuable matches handlers in
    # reverse registration order (last wins), not by specificity — so this overrides
    # the broad retry_on StandardError above for ArgumentError specifically.
    discard_on ArgumentError

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
            # Intentionally uses the GUARDED perform_later (single-child path),
            # unlike the bulk perform_all_later bypass in dispatch_children.
            child.job_klass.perform_later(child.key, **child.kwargs.symbolize_keys)
          end
      end
    end
  end
end
