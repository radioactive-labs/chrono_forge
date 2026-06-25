module ChronoForge
  module Dashboard
    class StatsQuery
      def counts
        grouped = ChronoForge::Workflow.group(:state).count
        by_name = grouped.transform_keys { |k| k.is_a?(Integer) ? ChronoForge::Workflow.states.key(k) : k.to_s }
        ChronoForge::Workflow.states.keys.index_with { |name| by_name[name].to_i }
      end
    end
  end
end
