module ChronoForge
  module Dashboard
    class WorkflowsController < BaseController
      def index
        @query = WorkflowsQuery.new(**list_params)
        @workflows = @query.results
        @stats = StatsQuery.new.counts
      end

      private

      def list_params
        params.permit(:state, :job_class, :key, :created_from, :created_to, :page)
          .to_h.symbolize_keys.merge(per: ChronoForge::Dashboard.config.page_size)
      end
    end
  end
end
