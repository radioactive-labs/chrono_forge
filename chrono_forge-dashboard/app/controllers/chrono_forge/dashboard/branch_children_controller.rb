module ChronoForge
  module Dashboard
    # The children of one branch — a keyset-paginated, filterable list scoped to a
    # single branch$ log's spawned_workflows. A branch can hold hundreds of
    # thousands of children, so we never render more than a page and default the
    # filter to "blocked" (failed + stalled) — the triage view that matters.
    class BranchChildrenController < BaseController
      def show
        @workflow = ChronoForge::Workflow.find(params[:workflow_id])
        @branch_log = @workflow.execution_logs.find(params[:id]) # scope to this workflow
        @branch = BranchPresenter.new(@branch_log)

        base = @branch_log.spawned_workflows
        @query = WorkflowsQuery.new(base: base, **list_params)
        @children = @query.records
        @waits = WaitStatePresenter.active_map(@children)

        stats = StatsQuery.new(base: base)
        @stats = stats.counts
        @stats_cap = stats.cap
      end

      private

      def list_params
        permitted = params.permit(:state, :job_class, :key, :before, :after).to_h.symbolize_keys
        # Land on the blockers, not page 1 of 500k, unless a filter is chosen.
        permitted[:state] = "blocked" unless params.key?(:state)
        permitted.merge(per: ChronoForge::Dashboard.config.page_size)
      end
    end
  end
end
