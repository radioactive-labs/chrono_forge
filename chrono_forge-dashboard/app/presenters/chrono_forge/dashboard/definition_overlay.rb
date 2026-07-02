module ChronoForge
  module Dashboard
    # Overlays a workflow run's execution_logs onto a static Definition, producing
    # per-node hashes with a runtime :status (and fan-out/repeat aggregates).
    # Read-only. The Definition is the static map; logs are the source of truth
    # for a specific run.
    class DefinitionOverlay
      # ExecutionLog's state enum is only pending/completed/failed. "pending" means
      # reached-but-unfinished (in progress), so it maps to :active; the fetch
      # default below catches any state added later.
      LOG_STATUS = {"completed" => :done, "failed" => :failed, "pending" => :active}.freeze

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
      # Bind it to the next log whose step_name matches its prefix pattern, in
      # creation order for a stable binding. Skip logs already owned by an exact
      # static node (reserved) or by an earlier dynamic node (consumed) so the same
      # run log never surfaces on two nodes — that double-report was the gap.
      def dynamic_status(node)
        pattern = node.step_name_pattern
        return {status: :not_reached} unless pattern
        log = candidate_logs.find do |l|
          l.step_name.start_with?(pattern) && !reserved.include?(l.step_name) &&
            !consumed.include?(l.step_name) && !framework_log?(l)
        end
        return {status: :not_reached} unless log
        consumed << log.step_name
        {status: LOG_STATUS.fetch(log_state(log), :active), step_name: log.step_name}
      end

      # Exact step_names claimed by static nodes — a dynamic prefix node must not
      # rebind these (its prefix, e.g. "durably_execute$", matches them all).
      def reserved = @reserved ||= @definition.nodes.filter_map(&:step_name).to_set

      # Loaded logs in a stable (creation) order, so dynamic prefix binding and
      # `consumed` tracking are deterministic rather than DB-load-order dependent.
      def candidate_logs = @candidate_logs ||= @workflow.execution_logs.sort_by(&:id)

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
        # Repetition logs are "<coord.step_name>$<tick>". Count them in Ruby over
        # already-loaded logs via an exact string prefix — a SQL LIKE would treat
        # the "_" in names like "durably_repeat$reconcile_ledger" as wildcards and
        # over-count rows from unrelated steps.
        prefix = "#{node.step_name}$"
        reps = candidate_logs.count { |l| l.step_name.start_with?(prefix) }
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

      # ExecutionLog#state is a Rails enum with exactly three values
      # (pending/completed/failed). A pending log is a step that has been reached
      # but hasn't finished, so it reads as :active. Guard the Integer case too.
      def log_state(log)
        state = log.state
        state.is_a?(String) ? state : ChronoForge::ExecutionLog.states.key(state).to_s
      end

      def coord_done?(log) = log_state(log) == "completed"
    end
  end
end
