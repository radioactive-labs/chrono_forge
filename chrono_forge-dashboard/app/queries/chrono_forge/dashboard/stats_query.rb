module ChronoForge
  module Dashboard
    # Per-state workflow counts, each capped so the panel never pays for an
    # unbounded COUNT. Each count is an index-only COUNT over a `LIMIT CAP`
    # subquery on the (state, ...) index, so it costs O(CAP) regardless of how
    # many rows match; a saturated count renders as "CAP+".
    class StatsQuery
      CAP = 5000

      def initialize(base: ChronoForge::Workflow.all, cap: CAP)
        @base = base
        @cap = cap
      end

      attr_reader :cap

      def counts
        ChronoForge::Workflow.states.keys.index_with do |name|
          capped(@base.where(state: ChronoForge::Workflow.states[name]))
        end
      end

      private

      def capped(relation)
        ChronoForge::Workflow.from(relation.reorder(nil).select(:id).limit(@cap), :capped).count
      end
    end
  end
end
