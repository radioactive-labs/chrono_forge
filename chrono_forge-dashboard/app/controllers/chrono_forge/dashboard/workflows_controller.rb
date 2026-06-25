module ChronoForge
  module Dashboard
    class WorkflowsController < BaseController
      def index
        render plain: "ChronoForge Dashboard"
      end
    end
  end
end
