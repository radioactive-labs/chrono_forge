module ChronoForge
  module Dashboard
    # Dedicated triage view for stalled workflows: oldest first (most urgent),
    # with the diagnostic context and per-row recovery actions in one place.
    class StalledController < BaseController
      CAP = 200

      def index
        scope = ChronoForge::Workflow
          .where(state: ChronoForge::Workflow.states[:stalled])
          .order(updated_at: :asc)
        @total = scope.limit(CAP + 1).count
        @capped = @total > CAP
        @rows = scope.limit(CAP).map { |wf| StalledPresenter.new(wf).row }
        @cap = CAP
      end
    end
  end
end
