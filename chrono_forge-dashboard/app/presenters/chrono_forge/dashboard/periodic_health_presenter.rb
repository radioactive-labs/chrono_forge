module ChronoForge
  module Dashboard
    class PeriodicHealthPresenter
      Task = Struct.new(:name, :last_execution_at, :next_scheduled_at, :timed_out_count, :latencies)

      def initialize(workflow) = @workflow = workflow

      def tasks
        coords = logs.select { |l| StepNameParser.parse(l.step_name).kind == :repeat_coordination }
        coords.map do |coord|
          name = StepNameParser.parse(coord.step_name).name
          runs = logs.select do |l|
            pp = StepNameParser.parse(l.step_name)
            pp.kind == :repeat_run && pp.name == name
          end
          Task.new(
            name: name,
            last_execution_at: coord.metadata&.dig("last_execution_at"),
            next_scheduled_at: next_scheduled(runs),
            timed_out_count: runs.count { |r| r.error_class == "TimeoutError" },
            latencies: runs.filter_map { |r| (r.completed_at - r.started_at).to_i if r.completed_at && r.started_at }
          )
        end
      end

      private

      # The next run is the not-yet-completed repetition with the furthest
      # scheduled time (each repetition log is named durably_repeat$name$<unix>).
      def next_scheduled(runs)
        ts = runs.reject(&:completed?)
          .filter_map { |r| StepNameParser.parse(r.step_name).timestamp }
          .max
        Time.zone.at(ts) if ts
      end

      def logs = @logs ||= @workflow.execution_logs.to_a
    end
  end
end
