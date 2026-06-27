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
      # Bound the metadata scan used to count fast-forwarded ticks (see #summary):
      # a pre-upgrade step may carry a long history of legacy per-tick rows.
      CATCHUP_SCAN_CAP = 1_000

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
      #
      # `tombstones` is the number of catch-up *rows* (cheap group count).
      # `skipped_ticks` is the true number of skipped ticks: a fast-forward
      # summary row collapses N expired ticks into one failed row tagged
      # `fast_forwarded: N`, so it counts as N, while a legacy per-tick tombstone
      # counts as 1. They diverge only once a fast-forward has happened.
      def summary
        @summary ||= begin
          by_state = scope.group(:state).count
          failed = by_state["failed"].to_i
          {
            iterations: by_state.values.sum,
            completed: by_state["completed"].to_i,
            tombstones: failed,
            skipped_ticks: failed.zero? ? 0 : skipped_tick_count,
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

      # Sum the skipped ticks across catch-up rows: each fast-forward summary row
      # contributes its `fast_forwarded` count; a legacy per-tick row contributes
      # 1. Bounded scan (only failed rows, capped) since metadata must be read.
      def skipped_tick_count
        scope.where(state: ChronoForge::ExecutionLog.states[:failed])
          .limit(CATCHUP_SCAN_CAP).pluck(:metadata)
          .sum { |m| [m&.dig("fast_forwarded").to_i, 1].max }
      end

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
