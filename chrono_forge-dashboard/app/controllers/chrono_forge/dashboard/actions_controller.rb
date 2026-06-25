module ChronoForge
  module Dashboard
    class ActionsController < BaseController
      rescue_from ChronoForge::Executor::WorkflowNotRetryableError do |e|
        redirect_to workflow_path(params[:id]), alert: e.message
      end

      def retry
        workflow.retry_later
        redirect_to workflow_path(workflow), notice: "Re-enqueued #{workflow.key}."
      end

      def unlock
        workflow.update!(locked_at: nil, locked_by: nil, state: :idle)
        redirect_to workflow_path(workflow), notice: "Unlocked #{workflow.key}."
      end

      def bulk_retry
        n = 0
        ChronoForge::Workflow.where(state: ChronoForge::Workflow.states[:failed]).find_each do |wf|
          wf.retry_later
          n += 1
        end
        redirect_to workflows_path, notice: "Re-enqueued #{n} failed workflow(s)."
      end

      private

      def workflow = @workflow ||= ChronoForge::Workflow.find(params[:id])
    end
  end
end
