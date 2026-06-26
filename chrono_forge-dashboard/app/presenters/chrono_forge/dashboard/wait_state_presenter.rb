module ChronoForge
  module Dashboard
    class WaitStatePresenter
      Active = Struct.new(:condition, :waiting_since, :timeout_at) do
        # A wait with a wake/timeout time still in the future is *scheduled*
        # (intentionally parked until then), not stuck.
        def scheduled?
          return false unless timeout_at
          t = timeout_at.is_a?(Time) ? timeout_at : Time.zone.parse(timeout_at.to_s)
          t&.future? || false
        end
      end

      def initialize(workflow) = @workflow = workflow

      def active
        return nil unless @workflow.idle?
        log = @workflow.execution_logs.order(Arel.sql("started_at, id")).last
        return nil unless log&.pending?
        return nil unless StepNameParser.parse(log.step_name).kind == :wait
        self.class.build(log)
      end

      # Active waits for a batch of workflows, in two queries instead of one per
      # row. Returns {workflow_id => Active} for idle workflows currently parked
      # on a pending wait_until. Bounded by the caller's workflow set.
      def self.active_map(workflows)
        ids = workflows.select(&:idle?).map(&:id)
        return {} if ids.empty?

        latest = {}
        ChronoForge::ExecutionLog
          .where(workflow_id: ids, state: ChronoForge::ExecutionLog.states[:pending])
          .where("step_name LIKE ?", "wait_until#{StepNameParser::DELIM}%")
          .order(Arel.sql("started_at, id"))
          .each { |log| latest[log.workflow_id] = log }

        latest.transform_values { |log| build(log) }
      end

      def self.build(log)
        p = StepNameParser.parse(log.step_name)
        Active.new(
          condition: p.name,
          waiting_since: log.last_executed_at || log.started_at,
          timeout_at: log.metadata&.dig("timeout_at")
        )
      end
    end
  end
end
