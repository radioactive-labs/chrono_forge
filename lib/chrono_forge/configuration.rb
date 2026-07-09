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

    # How long a single workflow pass may hold its lock before another job is
    # allowed to steal it (LockStrategy.acquire_lock treats a lock older than this
    # as stale). It bounds the assumed maximum duration of one execution pass.
    # Defaults to 10 minutes.
    attr_accessor :max_duration

    def initialize
      @branch_merge_queue = :default
      @max_duration = 10.minutes
      @reap_stale_after = nil
    end

    # Age past which a workflow still in :running is treated as stranded and
    # re-enqueued by ChronoForge::Workflow.reap_stalled. A workflow reaches this
    # state when its worker is hard-killed (SIGKILL/OOM/eviction) mid-pass, before
    # the executor's `ensure` block could release the lock and publish the resume
    # continuation — so it stays locked in :running with nothing scheduled to wake it.
    #
    # Defaults to 3x max_duration (30 min out of the box), so it always comfortably
    # exceeds the lock-steal threshold: acquire_lock only steals locks older than
    # max_duration, so a shorter reap threshold would just enqueue resume jobs that
    # immediately no-op via ConcurrentExecutionError. Deriving from max_duration keeps
    # that invariant automatic — raise max_duration and the reaper backs off with it.
    # An explicit value (set via the writer) overrides the derived default.
    def reap_stale_after
      @reap_stale_after || max_duration * 3
    end

    attr_writer :reap_stale_after
  end
end
