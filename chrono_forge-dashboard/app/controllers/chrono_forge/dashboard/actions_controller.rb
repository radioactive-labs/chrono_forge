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

      # Retry every blocked (failed/stalled) workflow. The fan-out runs in a
      # background job so the request returns fast even with a huge backlog; the
      # count is taken up front for the flash (BulkRetryJob does the enqueueing).
      def bulk_retry
        n = BulkRetryJob.retryable.count
        return redirect_to(workflows_path, notice: "No blocked workflows to retry.", status: :see_other) if n.zero?
        BulkRetryJob.perform_later
        redirect_to workflows_path, notice: "Retrying #{n} blocked workflow(s) in the background.", status: :see_other
      end

      # Retry every blocked (failed/stalled) child of one branch, in the background.
      def bulk_retry_branch
        parent = ChronoForge::Workflow.find(params[:workflow_id])
        branch_log = parent.execution_logs.find(params[:id])
        n = BulkRetryJob.retryable(branch_log).count
        redirect = ->(msg) { redirect_to workflow_branch_path(parent, branch_log), notice: msg, status: :see_other }
        return redirect.call("No blocked child workflows to retry.") if n.zero?
        BulkRetryJob.perform_later(branch_log.id)
        redirect.call("Retrying #{n} child workflow(s) in the background.")
      end

      private

      def workflow = @workflow ||= ChronoForge::Workflow.find(params[:id])
    end
  end
end
