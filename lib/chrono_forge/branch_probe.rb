# frozen_string_literal: true

module ChronoForge
  # Single source of truth for "is this branch done?" — used by both merge_branches
  # (boolean) and BranchMergeJob (which needs the sealed flag and pending count
  # separately for its adaptive poll cadence). Option A: only :completed counts as
  # done, so a failed/stalled child keeps the branch pending until recovered.
  module BranchProbe
    module_function

    # The branch's coordination log is sealed (fully dispatched).
    def sealed?(branch_log_id)
      ExecutionLog.where(id: branch_log_id, state: ExecutionLog.states[:completed]).exists?
    end

    # Relation of this branch's children that are not yet completed.
    def incomplete(branch_log_id)
      Workflow.where(parent_execution_log_id: branch_log_id)
        .where.not(state: Workflow.states[:completed])
    end

    # Relation of children that can advance on their own — actively running, or
    # dispatched-but-not-yet-started (started_at nil). This drives the adaptive
    # poll cadence. Deliberately EXCLUDES waiting children (idle with started_at
    # SET — parked on a wait/wait_until) and blocked children (failed/stalled —
    # awaiting operator recovery): polling can't make either progress, so they
    # must not pin the cadence at the responsive floor. They still count as
    # +incomplete+ (the branch stays open), they just don't accelerate polling.
    def progressing(branch_log_id)
      base = Workflow.where(parent_execution_log_id: branch_log_id)
      base.where(state: Workflow.states[:running])
        .or(base.where(state: Workflow.states[:idle], started_at: nil))
    end

    # A child of this branch is actively executing — a live worker will complete
    # it, so the poller can hold its responsive floor rather than backing off.
    def running?(branch_log_id)
      Workflow.where(parent_execution_log_id: branch_log_id, state: Workflow.states[:running]).exists?
    end

    # Children dispatched but not yet started (idle, started_at nil) — the queue of
    # never-started work for this branch. A DROP in this count between polls means
    # workers are actively pulling it off the queue (so a still-queued child is in
    # line, not dropped); the rekick gate keys off that. Distinct from total pending,
    # which a wait/wait_until child completing would drop without any never-started
    # child moving. (Not to be confused with the dashboard's "Dispatched" column,
    # which is the TOTAL children spawned.)
    def never_started(branch_log_id)
      Workflow.where(parent_execution_log_id: branch_log_id,
        state: Workflow.states[:idle], started_at: nil)
    end

    # A child was dispatched but no worker has started it yet. If this is the only
    # motion left, it's a queued/rekicked-but-unpicked straggler (which may never be
    # picked up), NOT active work — so the poller backs off.
    def never_started?(branch_log_id) = never_started(branch_log_id).exists?

    # All children spawned into this branch (every state) — the dispatch total. Fixed
    # once the branch is sealed, so the poller counts it exactly once and caches it on
    # the branch-log metadata. This is the dashboard's "Spawned" column. Distinct from
    # #never_started, which is only the idle-and-unstarted subset.
    def spawned(branch_log_id)
      Workflow.where(parent_execution_log_id: branch_log_id)
    end

    def done?(branch_log_id)
      sealed?(branch_log_id) && !incomplete(branch_log_id).exists?
    end
  end
end
