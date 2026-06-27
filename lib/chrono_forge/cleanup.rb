module ChronoForge
  # Reclaims storage from finished workflows and the unbounded execution-log
  # rows that periodic tasks (durably_repeat) accumulate.
  #
  # ChronoForge keeps every workflow and execution-log row indefinitely so that
  # replays stay idempotent. Two things grow without bound over time:
  #
  #   1. Terminal workflows (completed/failed) that are no longer needed.
  #   2. durably_repeat repetition logs — one row per scheduled execution. A
  #      long-lived periodic workflow never reaches a terminal state, so its
  #      repetition logs accumulate forever.
  #
  # This is not run automatically — schedule it from your own scheduler (cron,
  # Solid Queue recurring tasks, sidekiq-cron, GoodJob cron, the `whenever`
  # gem, ...). See ChronoForge::CleanupJob for a ready-made job, e.g.:
  #
  #   ChronoForge::Cleanup.run(
  #     older_than: 90.days,                       # default retention for terminal workflows
  #     failed_older_than: 180.days,               # keep failures longer for debugging
  #     prune_repetition_logs_older_than: 30.days  # opt in to periodic-log pruning
  #   )
  #
  # == Workflow retention is measured from when a workflow became terminal
  #
  # Retention is measured from the terminal transition, not created_at: a
  # long-running workflow may have been created long ago but only just finished.
  # Completed workflows use the immutable completed_at; failed workflows have no
  # completed_at, so they use updated_at (the failed! transition, after which
  # nothing touches the row — release_lock/context use update_columns/
  # update_column, which do not bump it).
  #
  # == Repetition-log pruning safety
  #
  # Pruning periodic logs is opt-in and deliberately conservative. A repetition
  # log is removed only when its scheduled time is BOTH older than the retention
  # window AND strictly before the periodic task's current frontier (the
  # coordination log's last_execution_at). Everything at or after the frontier is
  # kept, because durably_repeat's catch-up mechanism may still need it: the next
  # execution is computed as last_execution_at + every, so anything at/after the
  # frontier can still be revisited, while anything strictly before it never is.
  # Both checks use the scheduled time embedded in the step name rather than
  # created_at, which is misleading for catch-up rows created long after the
  # occurrence they represent. A task that has not executed yet (no frontier) is
  # never pruned.
  class Cleanup
    DEFAULT_RETENTION = 90.days
    DEFAULT_BATCH_SIZE = 1_000
    TERMINAL_LOG_STATES = %i[completed failed].freeze

    # @param older_than [ActiveSupport::Duration] default retention for terminal
    #   workflows; used for any state without a specific override.
    # @param completed_older_than [ActiveSupport::Duration, nil] retention for
    #   completed workflows. Defaults to older_than.
    # @param failed_older_than [ActiveSupport::Duration, nil] retention for
    #   failed workflows. Defaults to older_than.
    # @param prune_repetition_logs_older_than [ActiveSupport::Duration, nil]
    #   when set, also prune old terminal durably_repeat repetition logs from
    #   still-active workflows (see safety notes above). nil disables it.
    # @param batch_size [Integer] rows per delete batch.
    # @return [Hash] counts of deleted rows by category.
    def self.run(**)
      new(**).run
    end

    def initialize(older_than: DEFAULT_RETENTION, completed_older_than: nil, failed_older_than: nil,
      prune_repetition_logs_older_than: nil, batch_size: DEFAULT_BATCH_SIZE)
      @completed_older_than = completed_older_than || older_than
      @failed_older_than = failed_older_than || older_than
      @prune_repetition_logs_older_than = prune_repetition_logs_older_than
      @batch_size = batch_size
    end

    def run
      result = {workflows: 0, execution_logs: 0, error_logs: 0, repetition_logs: 0}

      # Completed workflows use the immutable completed_at; failed workflows
      # have no completed_at, so they fall back to updated_at.
      delete_terminal_workflows(:completed, :completed_at, @completed_older_than, result)
      delete_terminal_workflows(:failed, :updated_at, @failed_older_than, result)
      prune_repetition_logs(result) if @prune_repetition_logs_older_than

      result
    end

    private

    def delete_terminal_workflows(state, timestamp_column, older_than, result)
      cutoff = older_than.ago

      Workflow.where(state: state)
        .where(timestamp_column => ..cutoff)
        .in_batches(of: @batch_size) do |batch|
        ids = batch.ids
        next if ids.empty?

        # Branch children point at their parent's branch$ execution log via
        # parent_execution_log_id. Bulk delete bypasses the dependent: :nullify callback,
        # so nullify explicitly to avoid dangling references when a parent is reclaimed.
        Workflow.where(parent_execution_log_id: ExecutionLog.where(workflow_id: ids).select(:id))
          .update_all(parent_execution_log_id: nil)

        # Delete dependent rows in bulk rather than relying on row-by-row
        # dependent: :destroy callbacks.
        result[:execution_logs] += ExecutionLog.where(workflow_id: ids).delete_all
        result[:error_logs] += ErrorLog.where(workflow_id: ids).delete_all
        result[:workflows] += Workflow.where(id: ids).delete_all
      end
    end

    def prune_repetition_logs(result)
      cutoff = @prune_repetition_logs_older_than.ago.to_i

      coordination_logs.find_each do |coordination_log|
        frontier = coordination_frontier(coordination_log)
        next unless frontier

        # Repetition logs are "<coordination step_name>$<scheduled_at_unix>".
        # Match the prefix exactly in Ruby rather than via SQL LIKE: the step
        # name contains "_", a LIKE wildcard, so a LIKE pattern would need
        # escaping that is not portable across adapters.
        prefix = "#{coordination_log.step_name}$"

        # Scan in batches so a periodic workflow with a large backlog of
        # repetition logs (exactly the case cleanup exists to fix) never loads
        # them all into memory at once. Batching by primary key and only
        # deleting rows within the current batch keeps the cursor valid.
        ExecutionLog
          .where(workflow_id: coordination_log.workflow_id, state: TERMINAL_LOG_STATES)
          .in_batches(of: @batch_size) do |batch|
          prunable_ids = batch.pluck(:id, :step_name).filter_map do |id, step_name|
            next unless step_name.start_with?(prefix)

            scheduled_at = step_name.delete_prefix(prefix).to_i
            id if scheduled_at < frontier && scheduled_at < cutoff
          end

          result[:repetition_logs] += ExecutionLog.where(id: prunable_ids).delete_all if prunable_ids.any?
        end
      end
    end

    # Coordination logs are "durably_repeat$<name>" — exactly one "$" segment
    # after the prefix. Repetition logs add a second "$<timestamp>" segment.
    def coordination_logs
      ExecutionLog
        .where("step_name LIKE ?", "durably_repeat$%")
        .where.not("step_name LIKE ?", "durably_repeat$%$%")
        .order(:id)
    end

    def coordination_frontier(coordination_log)
      last_execution_at = coordination_log.metadata && coordination_log.metadata["last_execution_at"]
      return unless last_execution_at

      Time.parse(last_execution_at).to_i
    rescue ArgumentError, TypeError
      nil
    end
  end
end
