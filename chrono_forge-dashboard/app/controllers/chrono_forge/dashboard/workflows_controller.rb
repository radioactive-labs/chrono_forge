module ChronoForge
  module Dashboard
    class WorkflowsController < ActionController::Base
      def index
        render plain: "ChronoForge Dashboard"
      end
    end
  end
end
