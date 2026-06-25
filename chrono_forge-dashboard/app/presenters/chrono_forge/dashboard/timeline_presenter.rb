module ChronoForge
  module Dashboard
    class TimelinePresenter
      Entry = Struct.new(:id, :kind, :name, :status, :attempts, :started_at, :completed_at, :error, :runs, keyword_init: true)

      def initialize(workflow) = @workflow = workflow

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
        @ordered_logs ||= @workflow.execution_logs.order(Arel.sql("started_at, id")).to_a
      end

      def build
        coord_by_name = {}
        top = []
        ordered_logs.each do |l|
          p = StepNameParser.parse(l.step_name)
          entry = Entry.new(id: l.id, kind: p.kind, name: p.name, status: l.state,
            attempts: l.attempts, started_at: l.started_at, completed_at: l.completed_at,
            error: l.error_class, runs: [])
          if p.kind == :repeat_coordination
            coord_by_name[p.name] = entry
            top << entry
          elsif p.kind == :repeat_run && (parent = coord_by_name[p.name])
            parent.runs << entry
          else
            top << entry
          end
        end
        top
      end
    end
  end
end
