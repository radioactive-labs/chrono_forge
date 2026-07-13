module ChronoForge
  module Dashboard
    # Fleet-wide throughput: how much each workflow class has processed, plus its
    # current in-flight and blocked load. One GROUP BY (job_class, state) scan
    # feeds the whole page — the honest cost of a "totals across everything" view
    # (a total can't be capped the way StatsQuery caps the hot workflow list).
    class OverviewQuery
      IN_FLIGHT = %i[idle running].map { |s| ChronoForge::Workflow.states[s] }.freeze
      BLOCKED = %i[failed stalled].map { |s| ChronoForge::Workflow.states[s] }.freeze

      # A class's counts, bucketed the way the Overview reads them: processed
      # (done), in-flight (live work), blocked (needs triage).
      Row = Struct.new(:job_class, :processed, :in_flight, :blocked) do
        def total = processed + in_flight + blocked
      end

      # Fleet-wide card totals — each an independent COUNT so its turbo-frame can
      # load without paying for the per-class GROUP BY the table frame runs.
      def self.processed_total = ChronoForge::Workflow.completed.count

      def self.in_flight_total = ChronoForge::Workflow.where(state: IN_FLIGHT).count

      def self.blocked_total = ChronoForge::Workflow.where(state: BLOCKED).count

      def rows
        @rows ||= build_rows
      end

      # Synthetic bottom row summing every class.
      def totals
        @totals ||= Row.new(
          job_class: nil,
          processed: rows.sum(&:processed),
          in_flight: rows.sum(&:in_flight),
          blocked: rows.sum(&:blocked)
        )
      end

      private

      def build_rows
        grouped = ChronoForge::Workflow.group(:job_class, :state).count
        # enum key normalization: group(:state).count may key by the raw integer
        # (older Rails) or the label (newer) — invert states so either resolves.
        state_name = ChronoForge::Workflow.states.invert
        by_class = Hash.new { |h, k| h[k] = Hash.new(0) }
        grouped.each do |(klass, raw_state), n|
          by_class[klass][state_name[raw_state] || raw_state.to_s] += n
        end

        by_class.map { |klass, counts|
          Row.new(
            job_class: klass,
            processed: counts["completed"],
            in_flight: counts["idle"] + counts["running"],
            blocked: counts["failed"] + counts["stalled"]
          )
        }.sort_by { |r| [-r.processed, r.job_class.to_s] }
      end
    end
  end
end
