module ChronoForge
  module Executor
    module Methods
      module DurablyExecute
        # Executes a method with automatic retry logic and durable execution tracking.
        #
        # This method provides fault-tolerant execution of instance methods with automatic
        # retry on failure using exponential backoff. Each execution is tracked with its own
        # execution log, ensuring idempotent behavior during workflow replays.
        #
        # @param method [Symbol] The name of the instance method to execute
        # @param max_attempts [Integer] Maximum retry attempts before failing (default: 3)
        # @param name [String, nil] Custom name for the execution step. Defaults to method name.
        #   Used to create unique step names for execution logs.
        #
        # @return [nil]
        #
        # @raise [ExecutionFailedError] When the method fails after max_attempts
        #
        # @example Basic usage
        #   durably_execute :send_welcome_email
        #
        # @example With custom retry attempts
        #   durably_execute :critical_payment_processing, max_attempts: 5
        #
        # @example With custom name for tracking
        #   durably_execute :complex_calculation, name: "phase_1_calculation"
        #
        # @example Method that might fail temporarily
        #   def upload_to_s3
        #     # This might fail due to network issues, rate limits, etc.
        #     S3Client.upload(file_path, bucket: 'my-bucket')
        #     Rails.logger.info "Successfully uploaded file to S3"
        #   end
        #
        #   durably_execute :upload_to_s3, max_attempts: 5
        #
        # == Behavior
        #
        # === Idempotency
        # Each execution gets a unique step name ensuring that workflow replays don't
        # create duplicate executions. If a workflow is replayed and this step has
        # already completed, it will be skipped.
        #
        # === Retry Logic
        # - Failed executions are automatically retried with exponential backoff
        # - Backoff calculation: 2^attempt seconds (capped at 2^5 = 32 seconds)
        # - After max_attempts, ExecutionFailedError is raised
        #
        # === Error Handling
        # - All exceptions except HaltExecutionFlow are caught and handled
        # - Errors are logged and tracked in the execution log
        # - ExecutionFailedError is raised after exhausting all retry attempts
        # - HaltExecutionFlow exceptions are re-raised to allow workflow control flow
        #
        # === Execution Logs
        # Creates execution log with step name: `durably_execute$#{name || method}`
        # - Tracks attempt count, execution times, and completion status
        # - Stores error details when failures occur
        # - Enables monitoring and debugging of execution history
        #
        def durably_execute(method, max_attempts: 3, name: nil)
          step_name = "durably_execute$#{name || method}"
          # Find or create execution log
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
            send(method)

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
            if execution_log.attempts < max_attempts
              # Reschedule with exponential backoff
              backoff = (2**[execution_log.attempts, 5].min).seconds

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
