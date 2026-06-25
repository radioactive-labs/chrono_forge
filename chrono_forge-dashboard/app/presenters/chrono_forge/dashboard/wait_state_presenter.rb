module ChronoForge
  module Dashboard
    class WaitStatePresenter
      Active = Struct.new(:condition, :waiting_since, :timeout_at, keyword_init: true)

      def initialize(workflow) = @workflow = workflow

      def active
        return nil unless @workflow.idle?
        log = @workflow.execution_logs.order(Arel.sql("started_at, id")).last
        return nil unless log&.pending?
        p = StepNameParser.parse(log.step_name)
        return nil unless p.kind == :wait
        Active.new(
          condition: p.name,
          waiting_since: log.last_executed_at || log.started_at,
          timeout_at: log.metadata&.dig("timeout_at")
        )
      end
    end
  end
end
