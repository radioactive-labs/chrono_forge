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

    def done?(branch_log_id)
      sealed?(branch_log_id) && !incomplete(branch_log_id).exists?
    end
  end
end
