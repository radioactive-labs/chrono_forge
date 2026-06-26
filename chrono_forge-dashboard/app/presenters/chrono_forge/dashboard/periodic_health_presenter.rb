module ChronoForge
  module Dashboard
    # Health of a workflow's durably_repeat tasks. Never materializes the full run
    # history (which can be huge) — coordination logs are a tiny set, and each
    # task's run aggregates are computed with bounded/scoped queries that ride the
    # [workflow_id, step_name] index as range scans.
    class PeriodicHealthPresenter
      Task = Struct.new(:name, :last_execution_at, :next_scheduled_at, :timed_out_count, :latencies)

      RECENT = 20

      def initialize(workflow) = @workflow = workflow

      def tasks
        coordinations.map do |coord|
          name = StepNameParser.parse(coord.step_name).name
          Task.new(
            name: name,
            last_execution_at: parse_time(coord.metadata&.dig("last_execution_at")),
            next_scheduled_at: next_scheduled(name),
            timed_out_count: runs(name).where(error_class: "TimeoutError").count,
            latencies: recent_latencies(name)
          )
        end
      end

      private

      # The coordination logs (durably_repeat$name, no $ts suffix) — one per task.
      def coordinations
        @workflow.execution_logs
          .where("step_name LIKE ?", "durably_repeat#{d}%")
          .where.not("step_name LIKE ?", "durably_repeat#{d}%#{d}%")
          .to_a
      end

      def runs(name)
        @workflow.execution_logs.where("step_name LIKE ?", "durably_repeat#{d}#{name}#{d}%")
      end

      # Next run = the furthest-out not-yet-completed scheduled repetition. Pending
      # runs are few (the future-scheduled ones), so loading them is bounded.
      def next_scheduled(name)
        ts = runs(name).where(state: ChronoForge::ExecutionLog.states[:pending])
          .filter_map { |r| StepNameParser.parse(r.step_name).timestamp }.max
        Time.zone.at(ts) if ts
      end

      # Durations (seconds) of the most recent completed runs, oldest-first so the
      # summary's "last" is the newest. Bounded to RECENT rows.
      def recent_latencies(name)
        runs(name).where(state: ChronoForge::ExecutionLog.states[:completed])
          .where.not(started_at: nil, completed_at: nil)
          .order(id: :desc).limit(RECENT)
          .map { |r| (r.completed_at - r.started_at).to_i }.reverse
      end

      def parse_time(value)
        return nil if value.blank?
        value.is_a?(Time) ? value : Time.zone.parse(value.to_s)
      end

      def d = StepNameParser::DELIM
    end
  end
end
