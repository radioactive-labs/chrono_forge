module ChronoForge
  module Dashboard
    class WaitStatesController < BaseController
      # Bound the scan: at scale there can be tens of thousands of idle
      # workflows, so we examine at most CAP (oldest first) and resolve their
      # waits in a single batch query rather than one query per row.
      CAP = 500

      def index
        idle = ChronoForge::Workflow
          .where(state: ChronoForge::Workflow.states[:idle])
          .order(id: :asc)
          .limit(CAP + 1)
          .to_a
        @capped = idle.size > CAP
        idle = idle.first(CAP)

        waits = WaitStatePresenter.active_map(idle)
        @waits = idle.filter_map { |wf| {workflow: wf, wait: waits[wf.id]} if waits[wf.id] }
          .sort_by { |h| h[:wait].waiting_since || Time.current }
        @threshold = ChronoForge::Dashboard.config.long_wait_threshold
        @cap = CAP
      end
    end
  end
end
