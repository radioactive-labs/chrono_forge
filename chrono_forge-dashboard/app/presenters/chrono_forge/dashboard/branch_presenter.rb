module ChronoForge
  module Dashboard
    # Health of a single branch (a branch$<name> execution log) for the parent's
    # detail page. Every child count is CAPPED and index-only on
    # (parent_execution_log_id, state) — a branch can hold hundreds of thousands
    # of children, so we never count the full set, only up to CAP (shown "CAP+").
    class BranchPresenter
      CAP = 5000

      # merge_state: :merged | :merging | nil (not yet merged)
      def initialize(log, merge_state = nil)
        @log = log
        @merge_state = merge_state
      end

      attr_reader :log, :merge_state

      def name = StepNameParser.parse(@log.step_name).name

      # The branch is "sealed" once its block closed (done dispatching children).
      def sealed? = @log.completed?

      def dispatched = capped(children)
      def pending = capped(children.where.not(state: ChronoForge::Workflow.states[:completed]))
      def blocked = capped(children.where(state: BLOCKED_STATES))

      def cap = CAP

      BLOCKED_STATES = %i[failed stalled].map { |s| ChronoForge::Workflow.states[s] }.freeze

      # A scheduled next poll this far past due means the BranchMergeJob poller
      # likely never ran (queue latency aside) — a heuristic, hence "potential".
      POLL_OVERDUE_GRACE = 120 # seconds

      # The BranchMergeJob stamps its poll state onto the branch log's metadata
      # (it can't be queried from the backend; ActiveJob has no such API).
      def polled? = poll.present?
      def last_polled_at = parse_time(poll&.dig("last_polled_at"))
      def next_poll_at = parse_time(poll&.dig("next_poll_at"))
      def polls = poll&.dig("polls").to_i

      # next_poll_at is nil once the merge completes, so a finished merge never
      # looks overdue; a non-nil time well in the past = the poller is likely dead.
      def poll_overdue?
        t = next_poll_at
        t.present? && t < Time.current - POLL_OVERDUE_GRACE
      end

      private

      def children = @log.spawned_workflows

      def poll = @log.metadata&.dig("poll")

      def parse_time(value) = value.present? ? Time.zone.parse(value.to_s) : nil

      # Index-only COUNT over a LIMIT CAP subquery — O(CAP) regardless of how many
      # children match (mirrors StatsQuery).
      def capped(relation)
        ChronoForge::Workflow.from(relation.reorder(nil).select(:id).limit(CAP), :capped).count
      end
    end
  end
end
