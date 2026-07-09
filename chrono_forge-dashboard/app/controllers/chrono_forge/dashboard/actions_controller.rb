module ChronoForge
  module Dashboard
    class ActionsController < BaseController
      rescue_from ChronoForge::Executor::WorkflowNotRetryableError do |e|
        redirect_to workflow_path(params[:id]), alert: e.message, status: :see_other
      end

      def retry
        workflow.retry_later
        redirect_to workflow_path(workflow), notice: "Re-enqueued #{workflow.key}.", status: :see_other
      end

      def unlock
        workflow.update!(locked_at: nil, locked_by: nil, state: :idle)
        redirect_to workflow_path(workflow), notice: "Unlocked #{workflow.key}.", status: :see_other
      end

      # Re-enqueue an idle (parked) workflow so the executor picks it up again.
      # This is the recovery for a dropped poll/wake — a wait_until or merge whose
      # poller job was lost, or a continue_if whose event has since arrived: the
      # replay re-checks the condition and re-arms the poll if still unmet.
      def resume
        return redirect_to(workflow_path(workflow), alert: "Only idle workflows can be resumed.", status: :see_other) unless workflow.idle?
        workflow.job_klass.perform_later(workflow.key)
        redirect_to workflow_path(workflow), notice: "Re-enqueued #{workflow.key}.", status: :see_other
      end

      # Both failed and stalled workflows are retryable, so bulk retry covers
      # both (matching the per-workflow Retry, which uses `retryable?`).
      RETRYABLE_STATES = %i[failed stalled].map { |s| ChronoForge::Workflow.states[s] }.freeze

      def bulk_retry
        n = 0
        ChronoForge::Workflow.where(state: RETRYABLE_STATES).find_each do |wf|
          wf.retry_later
          n += 1
        end
        redirect_to workflows_path, notice: "Re-enqueued #{n} workflow(s).", status: :see_other
      end

      # Retry every blocked (failed/stalled) child of one branch.
      def bulk_retry_branch
        parent = ChronoForge::Workflow.find(params[:workflow_id])
        branch_log = parent.execution_logs.find(params[:id])
        n = 0
        branch_log.spawned_workflows.where(state: RETRYABLE_STATES).find_each do |wf|
          wf.retry_later
          n += 1
        end
        redirect_to workflow_branch_path(parent, branch_log), notice: "Re-enqueued #{n} child workflow(s).", status: :see_other
      end

      private

      def workflow = @workflow ||= ChronoForge::Workflow.find(params[:id])
    end
  end
end
