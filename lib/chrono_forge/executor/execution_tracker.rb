module ChronoForge
  module Executor
    class ExecutionTracker
      def self.track_error(workflow, error)
        # Create a detailed error log
        ErrorLog.create!(
          workflow: workflow,
          error_class: error.class.name,
          error_message: error.message,
          backtrace: error.backtrace.join("\n"),
          context: workflow.context
        )
      end
    end
  end
end
