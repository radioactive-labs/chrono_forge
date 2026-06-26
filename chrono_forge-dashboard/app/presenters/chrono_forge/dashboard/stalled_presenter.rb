module ChronoForge
  module Dashboard
    # Everything needed to diagnose and recover one stalled workflow, in a single
    # row: how long it has been stalled, who holds the lock, the last step that
    # ran, and the last error recorded.
    class StalledPresenter
      Row = Struct.new(:workflow, :stalled_since, :locked_by, :last_step, :last_error)

      def initialize(workflow) = @workflow = workflow

      def row
        log = @workflow.execution_logs.order(Arel.sql("started_at, id")).last
        Row.new(
          workflow: @workflow,
          stalled_since: @workflow.updated_at,
          locked_by: @workflow.locked_by,
          last_step: log && StepNameParser.parse(log.step_name),
          last_error: @workflow.error_logs.order(created_at: :desc).first
        )
      end
    end
  end
end
