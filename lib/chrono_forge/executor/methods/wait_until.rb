module ChronoForge
  module Executor
    class WaitConditionNotMet < ExecutionFailedError; end

    module Methods
      module WaitUntil
        # Waits until a specified condition becomes true, with configurable timeout and polling interval.
        #
        # This method provides durable waiting behavior that can survive workflow restarts and delays.
        # It periodically checks a condition method until it returns true or a timeout is reached.
        # The waiting state is persisted, making it resilient to system interruptions.
        #
        # @param condition [Symbol] The name of the instance method to evaluate as the condition.
        #   The method should return a truthy value when the condition is met.
        # @param timeout [ActiveSupport::Duration] Maximum time to wait for condition (default: 1.hour)
        # @param check_interval [ActiveSupport::Duration] Time between condition checks (default: 15.minutes)
        # @param retry_policy [RetryPolicy, nil] Policy governing errors raised *while
        #   evaluating the condition* (not the poll cadence). When nil, uses
        #   RetryPolicy.wait_default, which retries nothing — a raised condition fails
        #   fast. Pass a policy with `retry_on:` to opt specific errors into retrying.
        #   Note: unlike steps, wait_until does NOT inherit the class-level default.
        #
        # @return [true] When the condition is met
        #
        # @raise [WaitConditionNotMet] When timeout is reached before condition is met
        # @raise [ExecutionFailedError] When condition evaluation fails with non-retryable error
        #
        # @example Basic usage
        #   wait_until :payment_confirmed?
        #
        # @example With custom timeout and check interval
        #   wait_until :external_api_ready?, timeout: 30.minutes, check_interval: 1.minute
        #
        # @example With retry on specific errors
        #   wait_until :database_migration_complete?,
        #     timeout: 2.hours,
        #     check_interval: 30.seconds,
        #     retry_policy: RetryPolicy.new(retry_on: [ActiveRecord::ConnectionNotEstablished, Net::TimeoutError])
        #
        # @example Waiting for external system
        #   def third_party_service_ready?
        #     response = HTTParty.get("https://api.example.com/health")
        #     response.code == 200 && response.body.include?("healthy")
        #   end
        #
        #   wait_until :third_party_service_ready?,
        #     timeout: 1.hour,
        #     check_interval: 2.minutes,
        #     retry_policy: RetryPolicy.new(retry_on: [Net::TimeoutError, Net::HTTPClientException])
        #
        # @example Waiting for file processing
        #   def file_processing_complete?
        #     job_status = ProcessingJobStatus.find_by(file_id: @file_id)
        #     job_status&.completed? || false
        #   end
        #
        #   wait_until :file_processing_complete?,
        #     timeout: 45.minutes,
        #     check_interval: 30.seconds
        #
        # == Behavior
        #
        # === Condition Evaluation
        # The condition method is called on each check interval:
        # - Should return truthy value when condition is met
        # - Should return falsy value when condition is not yet met
        # - Can raise exceptions that will be handled based on the retry_policy
        #
        # === Timeout Handling
        # - Timeout is calculated from the first execution start time
        # - When timeout is reached, WaitConditionNotMet exception is raised
        # - Timeout checking happens before each condition evaluation
        #
        # === Error Handling
        # - Exceptions during condition evaluation are caught and logged
        # - If the retry_policy deems the error retryable, it triggers a retry with the
        #   policy's backoff
        # - Otherwise the error causes immediate failure with ExecutionFailedError
        # - Backoff is governed by the resolved RetryPolicy
        #
        # === Persistence and Resumability
        # - Wait state is persisted in execution logs with metadata
        # - Workflow can be stopped/restarted without losing wait progress
        # - Timeout calculation persists across restarts
        # - Check intervals are maintained even after system interruptions
        #
        # === Execution Logs
        # Creates execution log with step name: `wait_until$#{condition}`
        # - Stores timeout deadline and check interval in metadata
        # - Tracks attempt count and execution times
        # - Records final result (true for success, :timed_out for timeout)
        #
        def wait_until(condition, timeout: 1.hour, check_interval: 15.minutes, retry_policy: nil)
          policy = wait_retry_policy(retry_policy)
          validate_step_name_segment!(condition)
          step_name = "wait_until$#{condition}"
          # Find or create execution log
          execution_log = find_or_create_execution_log!(step_name) do |log|
            log.started_at = Time.current
            log.metadata = {
              timeout_at: timeout.from_now,
              check_interval: check_interval
            }
          end

          # Return if already completed
          if execution_log.completed?
            return execution_log.metadata["result"]
          end

          # Evaluate condition
          begin
            execution_log.update!(
              attempts: execution_log.attempts + 1,
              last_executed_at: Time.current
            )

            condition_met = send(condition)
          rescue HaltExecutionFlow
            raise
          rescue => e
            # Log the error
            Rails.logger.error { "Error evaluating condition #{condition}: #{e.message}" }
            self.class::ExecutionTracker.track_error(workflow, e, execution_log: execution_log)

            # Optional retry logic for errors raised while evaluating the
            # condition. The poll cadence (check_interval/timeout) below is
            # separate and unaffected by the retry policy.
            if policy.retryable?(e, execution_log.attempts)
              # Reschedule with the policy's backoff
              self.class
                .set(wait: policy.backoff_for(execution_log.attempts))
                .perform_later(
                  @workflow.key
                )

              # Halt current execution
              halt_execution!
            else
              execution_log.update!(
                state: :failed,
                error_message: e.message,
                error_class: e.class.name
              )
              raise ExecutionFailedError, "#{step_name} failed with an error: #{e.message}"
            end
          end

          # Handle condition met
          if condition_met
            execution_log.update!(
              state: :completed,
              completed_at: Time.current,
              error_message: "Execution timed out",
              error_class: "TimeoutError",
              metadata: execution_log.metadata.merge("result" => true)
            )
            return true
          end

          # Check for timeout
          metadata = execution_log.metadata
          if Time.current > metadata["timeout_at"]
            execution_log.update!(
              state: :failed,
              metadata: metadata.merge("result" => :timed_out)
            )
            Rails.logger.warn { "Timeout reached for condition '#{condition}'." }
            # Log here (with step context) rather than relying on the workflow-level
            # rescue, which no longer logs ExecutionFailedError.
            error = WaitConditionNotMet.new("Condition '#{condition}' not met within timeout period")
            self.class::ExecutionTracker.track_error(workflow, error, execution_log: execution_log)
            raise error
          end

          # Reschedule with delay
          self.class
            .set(wait: check_interval)
            .perform_later(
              @workflow.key,
              wait_condition: condition
            )

          # Halt current execution
          halt_execution!
        end
      end
    end
  end
end
