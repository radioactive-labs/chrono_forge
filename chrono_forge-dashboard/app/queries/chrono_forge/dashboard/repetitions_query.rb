module ChronoForge
  module Dashboard
    # The per-iteration run logs of a single durably_repeat step.
    #
    # These live on their own page rather than in the timeline: a long-running
    # periodic step can accumulate many runs — mostly catch-up "tombstones"
    # (expired/retried repetitions the engine marks failed and moves past) — and
    # inlining them would both bury the timeline and load an unbounded set.
    #
    # All access is keyed on `[workflow_id, step_name LIKE 'durably_repeat$step$%']`,
    # which rides the unique `[workflow_id, step_name]` index as a range scan, so
    # the summary counts and keyset pages stay cheap regardless of history depth.
    class RepetitionsQuery
      DEFAULT_PER = 50
      MAX_PER = 200

      def initialize(workflow:, step:, before: nil, after: nil, per: DEFAULT_PER)
        @workflow = workflow
        @step = step
        @before = before.presence&.to_i
        @after = after.presence&.to_i
        @per = per.to_i.clamp(1, MAX_PER)
      end

      attr_reader :workflow, :step, :per

      def records
        load
        @records
      end

      def has_next?
        load
        @has_next
      end

      def has_prev?
        load
        @has_prev
      end

      def next_cursor = records.last&.id
      def prev_cursor = records.first&.id

      # Cheap roll-up (counts + last run) without loading run rows. Grouping by
      # the `state` enum yields string-label keys ("completed"/"failed"), not
      # integers.
      def summary
        @summary ||= begin
          by_state = scope.group(:state).count
          {
            iterations: by_state.values.sum,
            completed: by_state["completed"].to_i,
            tombstones: by_state["failed"].to_i,
            last_run_at: scope.maximum(:started_at)
          }
        end
      end

      def scope
        @workflow.execution_logs.where(
          "step_name LIKE ?",
          "durably_repeat#{StepNameParser::DELIM}#{@step}#{StepNameParser::DELIM}%"
        )
      end

      private

      def load
        return if @loaded
        @loaded = true
        col = "#{ChronoForge::ExecutionLog.table_name}.id"

        if @after
          rows = scope.where("#{col} > ?", @after).order(id: :asc).limit(@per + 1).to_a
          @has_prev = rows.size > @per
          @records = rows.first(@per).reverse
          @has_next = true
        else
          s = scope
          s = s.where("#{col} < ?", @before) if @before
          rows = s.order(id: :desc).limit(@per + 1).to_a
          @has_next = rows.size > @per
          @records = rows.first(@per)
          @has_prev = @before.present?
        end
      end
    end
  end
end
