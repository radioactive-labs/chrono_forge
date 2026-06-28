module ChronoForge
  module Dashboard
    class WorkflowsController < BaseController
      def index
        @hide_branches = params[:hide_branches] != "0" # on by default
        @query = WorkflowsQuery.new(**list_params, exclude_branched: @hide_branches)
        @workflows = @query.records
        @waits = WaitStatePresenter.active_map(@workflows)
        # Stats track the toggle so the counts match the visible list — a large
        # fan-out's children don't dominate the totals while hidden from the list.
        stats_base = @hide_branches ? ChronoForge::Workflow.where(parent_execution_log_id: nil) : ChronoForge::Workflow.all
        stats = StatsQuery.new(base: stats_base)
        @stats = stats.counts
        @stats_cap = stats.cap
      end

      def show
        @workflow = ChronoForge::Workflow.find(params[:id])
        @timeline = TimelinePresenter.new(@workflow)
        @context = ContextPresenter.new(@workflow)
        @wait = WaitStatePresenter.new(@workflow).active
        @periodic = PeriodicHealthPresenter.new(@workflow).tasks
        @branches = BranchesPresenter.new(@workflow)
        @parent_log = @workflow.parent_execution_log
      end

      private

      def list_params
        params.permit(:state, :job_class, :key, :created_from, :created_to, :before, :after)
          .to_h.symbolize_keys.merge(per: ChronoForge::Dashboard.config.page_size)
      end
    end
  end
end
