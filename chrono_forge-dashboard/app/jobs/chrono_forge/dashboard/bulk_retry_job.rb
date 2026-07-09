module ChronoForge
  module Dashboard
    # Fans out per-workflow retries off the request thread. The "Retry blocked"
    # buttons enqueue one of these instead of looping in the controller, so the
    # HTTP request stays fast even when thousands of workflows are blocked.
    class BulkRetryJob < ActiveJob::Base
      # Both failed and stalled workflows are retryable (matching the per-workflow
      # Retry, which uses `retryable?`).
      RETRYABLE_STATES = %i[failed stalled].map { |s| ChronoForge::Workflow.states[s] }.freeze

      # The blocked workflows a run would retry: all of them, or just one branch's
      # spawned children. Exposed so the controller can report a count up front.
      def self.retryable(branch_log = nil)
        base = branch_log ? branch_log.spawned_workflows : ChronoForge::Workflow.all
        base.where(state: RETRYABLE_STATES)
      end

      def perform(branch_log_id = nil)
        branch_log = branch_log_id && ChronoForge::ExecutionLog.find(branch_log_id)
        self.class.retryable(branch_log).find_each(&:retry_later)
      end
    end
  end
end
