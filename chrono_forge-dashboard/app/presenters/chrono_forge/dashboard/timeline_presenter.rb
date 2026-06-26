module ChronoForge
  module Dashboard
    class TimelinePresenter
      Entry = Struct.new(:id, :kind, :name, :step_name, :status, :attempts,
        :started_at, :completed_at, :last_executed_at, :error_class, :error_message,
        :errors, :iterations, :tombstones, :last_run_at)

      # Per-iteration run logs of a durably_repeat step are excluded from the
      # timeline (they get their own paginated page) and summarized instead.
      RUN_PATTERN = "durably_repeat#{StepNameParser::DELIM}%#{StepNameParser::DELIM}%".freeze

      def initialize(workflow) = @workflow = workflow

      attr_reader :workflow

      def entries
        @entries ||= build
      end

      def current_position
        logs = ordered_logs
        logs.reverse.find { |l| l.failed? } ||
          logs.reverse.find { |l| l.pending? && StepNameParser.parse(l.step_name).kind == :wait } ||
          logs.last
      end

      private

      def ordered_logs
        @ordered_logs ||= @workflow.execution_logs
          .where.not("step_name LIKE ?", RUN_PATTERN)
          .order(Arel.sql("started_at, id")).to_a
      end

      def build
        errors_by_step = @workflow.error_logs.order(:attempt, :created_at).to_a.group_by(&:step_name)
        ordered_logs.map do |l|
          p = StepNameParser.parse(l.step_name)
          entry = Entry.new(id: l.id, kind: p.kind, name: p.name, step_name: l.step_name,
            status: l.state, attempts: l.attempts, started_at: l.started_at,
            completed_at: l.completed_at, last_executed_at: l.last_executed_at,
            error_class: l.error_class, error_message: l.error_message,
            errors: errors_by_step[l.step_name] || [])
          summarize_repetitions(entry, p.name) if p.kind == :repeat_coordination
          entry
        end
      end

      def summarize_repetitions(entry, name)
        s = RepetitionsQuery.new(workflow: @workflow, step: name).summary
        entry.iterations = s[:iterations]
        entry.tombstones = s[:tombstones]
        entry.last_run_at = s[:last_run_at]
      end
    end
  end
end
