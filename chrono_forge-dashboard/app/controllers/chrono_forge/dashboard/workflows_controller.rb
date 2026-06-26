module ChronoForge
  module Dashboard
    class WorkflowsController < BaseController
      def index
        @query = WorkflowsQuery.new(**list_params)
        @workflows = @query.records
        @waits = WaitStatePresenter.active_map(@workflows)
        stats = StatsQuery.new
        @stats = stats.counts
        @stats_cap = stats.cap
      end

      def show
        @workflow = ChronoForge::Workflow.find(params[:id])
        @timeline = TimelinePresenter.new(@workflow)
        @context = ContextPresenter.new(@workflow)
        @wait = WaitStatePresenter.new(@workflow).active
        @periodic = PeriodicHealthPresenter.new(@workflow).tasks
      end

      private

      def list_params
        params.permit(:state, :job_class, :key, :created_from, :created_to, :before, :after)
          .to_h.symbolize_keys.merge(per: ChronoForge::Dashboard.config.page_size)
      end
    end
  end
end
