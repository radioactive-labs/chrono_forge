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

      # Live throughput/ETA from the last poll (the poller measures the branch's
      # completion rate each pass). The wake poll records rate 0, so a positive rate
      # means the branch is still draining — a merged/idle branch shows no gauge.
      def rate = poll&.dig("rate").to_f

      def eta_seconds = poll&.dig("eta_seconds")

      def throughput? = rate > 0

      # Children dispatched but not yet started (idle, started_at nil) — how much of
      # this branch hasn't been picked up yet. Capped/index-only like the other counts.
      def never_started = capped(children.where(state: ChronoForge::Workflow.states[:idle], started_at: nil))

      # The FULL (uncapped) pending / never-started counts the poller ALREADY records
      # each pass — so the dashboard can show the real number instead of the capped
      # "CAP+", with NO new query. nil until the branch has been polled; callers fall
      # back to the capped count. (The poll's "never_started" is the never-started count.)
      def exact_pending = poll&.dig("pending")

      def exact_never_started = poll&.dig("never_started")

      # Dropped-child recovery: how many children the poller has rekicked, and when
      # it last did (nil if never).
      def rekicks = poll&.dig("rekick_total").to_i

      def last_rekick_at = parse_time(poll&.dig("last_rekick_at"))

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
