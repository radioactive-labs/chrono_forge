module ChronoForge
  module Dashboard
    class WaitStatePresenter
      # kind: :wait (wait_until — polls, has a timeout) or :continue (continue_if
      # — waits on an external event, NO timeout, never self-resumes). A stuck
      # continue_if is the silent killer: a webhook that never arrives leaves the
      # workflow parked forever with nothing to flag it.
      Active = Struct.new(:kind, :condition, :waiting_since, :timeout_at) do
        # Only a time-based wait with a wake time still in the future is
        # "scheduled" (intentionally parked until then). Event waits never are.
        def scheduled?
          return false unless kind == :wait && timeout_at
          t = timeout_at.is_a?(Time) ? timeout_at : Time.zone.parse(timeout_at.to_s)
          t&.future? || false
        end

        def event_wait? = kind == :continue
      end

      WAIT_KINDS = %i[wait continue].freeze

      def initialize(workflow) = @workflow = workflow

      def active
        return nil unless @workflow.idle?
        log = @workflow.execution_logs.order(Arel.sql("started_at, id")).last
        return nil unless log&.pending?
        return nil unless WAIT_KINDS.include?(StepNameParser.parse(log.step_name).kind)
        self.class.build(log)
      end

      # Active waits for a batch of workflows, in two queries instead of one per
      # row. Returns {workflow_id => Active} for idle workflows currently parked
      # on a pending wait_until or continue_if. Bounded by the caller's set.
      def self.active_map(workflows)
        ids = workflows.select(&:idle?).map(&:id)
        return {} if ids.empty?

        d = StepNameParser::DELIM
        latest = {}
        ChronoForge::ExecutionLog
          .where(workflow_id: ids, state: ChronoForge::ExecutionLog.states[:pending])
          .where("step_name LIKE ? OR step_name LIKE ?", "wait_until#{d}%", "continue_if#{d}%")
          .order(Arel.sql("started_at, id"))
          .each { |log| latest[log.workflow_id] = log }

        latest.transform_values { |log| build(log) }
      end

      def self.build(log)
        p = StepNameParser.parse(log.step_name)
        Active.new(
          kind: p.kind,
          condition: p.name,
          waiting_since: log.last_executed_at || log.started_at,
          timeout_at: log.metadata&.dig("timeout_at")
        )
      end
    end
  end
end
