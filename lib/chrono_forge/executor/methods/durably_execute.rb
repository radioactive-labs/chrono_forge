module ChronoForge
  module Executor
    module Methods
      module DurablyExecute
        def durably_execute(method, **options)
          # Create execution log
          step_name = "durably_execute$#{method}"
          execution_log = ExecutionLog.create_or_find_by!(
            workflow: @workflow,
            step_name: step_name
          ) do |log|
            log.started_at = Time.current
          end

          # Return if already completed
          return if execution_log.completed?

          # Execute with error handling
          begin
            # Update execution log with attempt
            execution_log.update!(
              attempts: execution_log.attempts + 1,
              last_executed_at: Time.current
            )

            # Execute the method
            if method.is_a?(Symbol)
              send(method)
            else
              method.call(@context)
            end

            # Complete the execution
            execution_log.update!(
              state: :completed,
              completed_at: Time.current
            )

            # return nil
            nil
          rescue HaltExecutionFlow
            raise
          rescue => e
            # Log the error
            Rails.logger.error { "Error while durably executing #{method}: #{e.message}" }
            self.class::ExecutionTracker.track_error(workflow, e)

            # Optional retry logic
            if execution_log.attempts < (options[:max_attempts] || 3)
              # Reschedule with exponential backoff
              backoff = (2**[execution_log.attempts || 1, 5].min).seconds

              self.class
                .set(wait: backoff)
                .perform_later(
                  @workflow.key,
                  retry_method: method
                )

              # Halt current execution
              halt_execution!
            else
              # Max attempts reached
              execution_log.update!(
                state: :failed,
                error_message: e.message,
                error_class: e.class.name
              )
              raise ExecutionFailedError, "#{step_name} failed after maximum attempts"
            end
          end
        end
      end
    end
  end
end
