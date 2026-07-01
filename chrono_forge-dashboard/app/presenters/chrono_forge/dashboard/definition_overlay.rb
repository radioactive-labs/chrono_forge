module ChronoForge
  module Dashboard
    # Overlays a workflow run's execution_logs onto a static Definition, producing
    # per-node hashes with a runtime :status (and fan-out/repeat aggregates).
    # Read-only. The Definition is the static map; logs are the source of truth
    # for a specific run.
    class DefinitionOverlay
      LOG_STATUS = {"completed" => :done, "running" => :active,
                    "failed" => :failed, "stalled" => :stalled}.freeze

      def initialize(definition, workflow)
        @definition = definition
        @workflow = workflow
      end

      def nodes
        mapped = @definition.nodes.map { |n| overlay(n) }
        mapped + unmapped_nodes(mapped)
      end

      def warnings = @definition.warnings

      private

      def overlay(node)
        base = node.to_h.merge(status: :not_reached)
        case node.kind
        when :branch then base.merge(fanout_status(node))
        when :repeat then base.merge(repeat_status(node))
        when :dynamic then base.merge(dynamic_status(node))
        else
          log = logs_by_name[node.step_name]
          log ? base.merge(status: LOG_STATUS.fetch(log_state(log), :active)) : base
        end
      end

      # A dynamic node has no exact step_name (its name is computed at runtime).
      # Bind it to the next unconsumed log whose step_name matches its prefix
      # pattern (prefix + ordinal), and record the log as consumed so it does NOT
      # also surface as a separate :unmapped node — that double-report was the gap.
      def dynamic_status(node)
        pattern = node.step_name_pattern
        return {status: :not_reached} unless pattern
        log = @workflow.execution_logs.find do |l|
          l.step_name.start_with?(pattern) && !consumed.include?(l.step_name) && !framework_log?(l)
        end
        return {status: :not_reached} unless log
        consumed << log.step_name
        {status: LOG_STATUS.fetch(log_state(log), :active), step_name: log.step_name}
      end

      def fanout_status(node)
        log = logs_by_name[node.step_name]
        return {status: :not_reached} unless log
        counts = ChronoForge::Workflow
          .where(parent_execution_log_id: log.id)
          .group(:state).count
          .transform_keys { |k| ChronoForge::Workflow.states.key(k) || k.to_s }
        status = if counts["failed"].to_i.positive?
          :failed
        elsif counts.except("completed").values.sum.positive?
          :active
        elsif counts.any?
          :done
        else
          :not_reached
        end
        {status: status, counts: counts}
      end

      def repeat_status(node)
        coord = logs_by_name[node.step_name]
        return {status: :not_reached} unless coord
        reps = @workflow.execution_logs
          .where("step_name LIKE ?", "#{node.step_name}$%").count
        {status: (coord_done?(coord) ? :done : :active), repetitions: reps}
      end

      def consumed = @consumed ||= Set.new

      def unmapped_nodes(mapped)
        known = mapped.filter_map { |n| n[:step_name] }.to_set
        @workflow.execution_logs
          .select { |l| l.completed? }
          .reject { |l| known.include?(l.step_name) || consumed.include?(l.step_name) || framework_log?(l) }
          .map do |l|
            {id: "log-#{l.id}", kind: :dynamic, label: l.step_name, step_name: l.step_name,
             status: :unmapped, warnings: ["no matching static node"]}
          end
      end

      # Skip framework-internal and fan-out child/rep logs (aggregated elsewhere).
      def framework_log?(log)
        log.step_name.start_with?("$") || log.step_name.count("$") >= 2
      end

      def logs_by_name
        @logs_by_name ||= @workflow.execution_logs.index_by(&:step_name)
      end

      # ExecutionLog#state is a Rails enum, so it already reads back as the String
      # key ("completed"/"failed"/…). Guard the Integer case too for safety.
      def log_state(log)
        state = log.state
        state.is_a?(String) ? state : ChronoForge::ExecutionLog.states.key(state).to_s
      end

      def coord_done?(log) = log_state(log) == "completed"
    end
  end
end
