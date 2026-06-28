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
        # @param retry_policy [RetryPolicy, nil] Per-call retry policy. When nil,
        #   uses the class-level `retry_policy` default, then the step built-in
        #   (RetryPolicy.step_default: 3 attempts, exponential backoff capped at 30s).
        # @param name [String, nil] Custom name for the execution step. Defaults to method name.
        #   Used to create unique step names for execution logs.
        #
        # @return [nil]
        #
        # @raise [ExecutionFailedError] When the method fails after the policy's max_attempts
        #
        # @example Basic usage
        #   durably_execute :send_welcome_email
        #
        # @example With a custom retry policy
        #   durably_execute :critical_payment_processing,
        #     retry_policy: RetryPolicy.new(max_attempts: 5)
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
        #   durably_execute :upload_to_s3, retry_policy: RetryPolicy.new(max_attempts: 5)
        #
        # == Behavior
        #
        # === Idempotency
        # Each execution gets a unique step name ensuring that workflow replays don't
        # create duplicate executions. If a workflow is replayed and this step has
        # already completed, it will be skipped.
        #
        # === Retry Logic
        # - Failed executions are retried per the resolved RetryPolicy
        # - Backoff and attempt cap come from that policy (see RetryPolicy)
        # - After the policy's max_attempts, ExecutionFailedError is raised
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
        def durably_execute(method, retry_policy: nil, name: nil)
          policy = step_retry_policy(retry_policy)
          validate_step_name_segment!(name || method)
          step_name = "durably_execute$#{name || method}"
          # Find or create execution log. On a fresh step the first attempt is
          # recorded in the INSERT itself (attempts: 1, last_executed_at) so there
          # is no separate pre-execution UPDATE to follow it.
          execution_log = find_or_create_execution_log!(step_name) do |log|
            now = Time.current
            log.started_at = now
            log.last_executed_at = now
            log.attempts = 1
          end

          # Return if already completed
          return if execution_log.completed?

          # Execute with error handling
          begin
            # Existing logs (retries) still need the pre-execution attempt bump;
            # a freshly-created log already recorded its first attempt above.
            unless execution_log.previously_new_record?
              execution_log.update!(
                attempts: execution_log.attempts + 1,
                last_executed_at: Time.current
              )
            end

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
            self.class::ExecutionTracker.track_error(workflow, e, execution_log: execution_log)

            # Optional retry logic
            backoff = policy.retry_backoff(e, attempts: execution_log.attempts) do |policy_key|
              bump_retry_count!(execution_log, policy_key)
            end
            if backoff
              # Reschedule with the policy's backoff (published after lock release).
              # The workflow replays on resume and skips completed steps, so the
              # rescheduled run picks this step up again by its execution log.
              enqueue_continuation(wait: backoff)

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
