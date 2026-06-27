module ChronoForge
  module Dashboard
    class TimelinePresenter
      Entry = Struct.new(:id, :kind, :name, :step_name, :status, :attempts,
        :started_at, :completed_at, :last_executed_at, :error_class, :error_message,
        :metadata, :errors, :missing_error_id, :iterations, :tombstones, :last_run_at)

      # Per-iteration run logs of a durably_repeat step are excluded from the
      # timeline (they get their own paginated page) and summarized instead.
      RUN_PATTERN = "durably_repeat#{StepNameParser::DELIM}%#{StepNameParser::DELIM}%".freeze

      def initialize(workflow) = @workflow = workflow

      attr_reader :workflow

      def entries
        @entries ||= build
      end

      # Error logs not shown on any step — workflow-level failures whose step_name
      # is nil and that aren't linked to a $workflow_failure$ marker. Surfaced so
      # a failure is never invisible. (Repeat-run errors live on the repetitions
      # page, so they're excluded.)
      def orphan_errors
        entries
        @orphan_errors
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
        all_errors = @workflow.error_logs.order(:attempt, :created_at).to_a
        by_step = all_errors.group_by(&:step_name)
        by_id = all_errors.index_by(&:id)
        shown = []

        entries = ordered_logs.map do |l|
          p = StepNameParser.parse(l.step_name)
          errors = (by_step[l.step_name] || []).dup
          # A workflow-level failure ($workflow_failure$<id>) records its error
          # with a nil step_name, so attach it to the marker by id. If that error
          # log is gone (independently pruned), note the id so the marker still
          # says *something* rather than rendering an errorless failure.
          missing_error_id = nil
          if p.kind == :lifecycle && p.name == "failure" && p.timestamp
            if (err = by_id[p.timestamp])
              errors << err unless errors.include?(err)
            else
              missing_error_id = p.timestamp
            end
          end
          shown.concat(errors)
          entry = Entry.new(id: l.id, kind: p.kind, name: p.name, step_name: l.step_name,
            status: l.state, attempts: l.attempts, started_at: l.started_at,
            completed_at: l.completed_at, last_executed_at: l.last_executed_at,
            error_class: l.error_class, error_message: l.error_message,
            metadata: l.metadata, errors: errors, missing_error_id: missing_error_id)
          summarize_repetitions(entry, p.name) if p.kind == :repeat_coordination
          entry
        end

        @orphan_errors = (all_errors - shown).reject { |e| e.step_name.to_s.match?(RUN_PATTERN_RX) }
        entries
      end

      RUN_PATTERN_RX = /\Adurably_repeat#{Regexp.escape(StepNameParser::DELIM)}.+#{Regexp.escape(StepNameParser::DELIM)}/

      def summarize_repetitions(entry, name)
        s = RepetitionsQuery.new(workflow: @workflow, step: name).summary
        entry.iterations = s[:iterations]
        entry.tombstones = s[:tombstones]
        entry.last_run_at = s[:last_run_at]
      end
    end
  end
end
