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
      end
    end
  end
end
