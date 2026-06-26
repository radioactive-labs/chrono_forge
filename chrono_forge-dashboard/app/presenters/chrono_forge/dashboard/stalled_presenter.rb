module ChronoForge
  module Dashboard
    # Everything needed to diagnose and recover one stalled workflow, in a single
    # row: how long ago it stalled, the last step that ran, and the last error.
    #
    # A stalled workflow holds NO lock — the executor sets `stalled!` when a step
    # exhausts its retries and then releases the lock. A workflow whose worker
    # died mid-step is a different case (it stays `running` with a stale lock,
    # recovered via force-unlock), not surfaced here.
    class StalledPresenter
      Row = Struct.new(:workflow, :stalled_since, :last_step, :last_error)

      def initialize(workflow) = @workflow = workflow

      def row
        # The stall cause is a failed step, so prefer the most recent failed
        # step; fall back to the last step otherwise. Background durably_repeat
        # runs (tombstones) are excluded — they don't stall the workflow.
        logs = @workflow.execution_logs
          .where.not("step_name LIKE ?", TimelinePresenter::RUN_PATTERN)
          .order(Arel.sql("started_at, id")).to_a
        step_log = logs.reverse.find(&:failed?) || logs.last
        Row.new(
          workflow: @workflow,
          stalled_since: @workflow.updated_at,
          last_step: step_log && StepNameParser.parse(step_log.step_name),
          last_error: @workflow.error_logs.order(created_at: :desc).first
        )
      end
    end
  end
end
