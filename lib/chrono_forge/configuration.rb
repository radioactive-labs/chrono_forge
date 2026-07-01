# frozen_string_literal: true

module ChronoForge
  # Engine-wide configuration. Set via ChronoForge.configure in an initializer.
  class Configuration
    # The queue the branch-merge poller (BranchMergeJob) runs on.
    #
    # This MUST NOT be a queue that a fan-out's own children saturate: merge_branches
    # enqueues the poller AFTER dispatching the branch's children, so on a shared
    # queue it is starved behind the whole backlog and only gets a worker slot near
    # the end — it then polls once, at pending≈0, and backs off, so the parent's
    # convergence lags by up to max_interval and no mid-drain throughput is recorded.
    # Because the poller is OUR code (not the user's job), its placement is a
    # first-class setting rather than something to monkey-patch onto BranchMergeJob.
    #
    # Defaults to :default (fine when fan-outs run on their own queues). For large
    # fan-outs, point this at a dedicated queue with its own worker so the poller
    # runs promptly throughout the drain.
    attr_accessor :branch_merge_queue

    def initialize
      @branch_merge_queue = :default
    end
  end
end
