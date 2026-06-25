module ChronoForge
  module Dashboard
    class WaitStatesController < BaseController
      def index
        idle = ChronoForge::Workflow.where(state: ChronoForge::Workflow.states[:idle])
        @waits = idle.filter_map do |wf|
          a = WaitStatePresenter.new(wf).active
          {workflow: wf, wait: a} if a
        end.sort_by { |h| h[:wait].waiting_since || Time.current }
        @threshold = ChronoForge::Dashboard.config.long_wait_threshold
      end
    end
  end
end
