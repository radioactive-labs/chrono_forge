module ChronoForge
  module Dashboard
    # The full, keyset-paginated list of a durably_repeat step's per-iteration
    # runs — kept off the workflow timeline so a deep repetition history neither
    # buries the timeline nor loads unbounded.
    class RepetitionsController < BaseController
      def index
        @workflow = ChronoForge::Workflow.find(params[:id])
        @step = params.require(:step)
        @query = RepetitionsQuery.new(
          workflow: @workflow, step: @step,
          before: params[:before], after: params[:after],
          per: ChronoForge::Dashboard.config.page_size
        )
        @runs = @query.records
        @summary = @query.summary
      end
    end
  end
end
