module ChronoForge
  module Dashboard
    # Analytics live on their own page so the workflow list stays fast (no
    # aggregation on the hot path). With a `class` param the same view is scoped
    # to a single workflow class, linked from the workflow detail.
    class AnalyticsController < BaseController
      def index
        @query = AnalyticsQuery.new(window: params[:window], job_class: params[:class])
        @job_class = @query.job_class
        @buckets = @query.buckets
        @totals = @query.totals
        @top_errors = @query.top_errors

        # Current queue health for the class (capped, all-time) complements the
        # windowed throughput above. Only shown per-class; the workflow list's
        # stats strip already covers the global breakdown.
        if @job_class
          @queue = StatsQuery.new(base: ChronoForge::Workflow.where(job_class: @job_class))
        end
      end
    end
  end
end
