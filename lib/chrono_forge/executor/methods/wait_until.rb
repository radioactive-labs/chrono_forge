module ChronoForge
  module Executor
    class WaitConditionNotMet < ExecutionFailedError; end

    module Methods
      module WaitUntil
        def wait_until(condition, **options)
          # Default timeout and check interval
          timeout = options[:timeout] || 10.seconds
          check_interval = options[:check_interval] || 1.second

          # Find or create execution log
          step_name = "wait_until$#{condition}"
          execution_log = ExecutionLog.create_or_find_by!(
            workflow: @workflow,
            step_name: step_name
          ) do |log|
            log.started_at = Time.current
            log.metadata = {
              timeout_at: timeout.from_now,
              check_interval: check_interval,
              condition: condition.to_s
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

            condition_met = if condition.is_a?(Proc)
              condition.call(@context)
            elsif condition.is_a?(Symbol)
              send(condition)
            else
              raise ArgumentError, "Unsupported condition type"
            end
          rescue HaltExecutionFlow
            raise
          rescue => e
            # Log the error
            Rails.logger.error { "Error evaluating condition #{condition}: #{e.message}" }
            self.class::ExecutionTracker.track_error(workflow, e)

            # Optional retry logic
            if (options[:retry_on] || []).include?(e.class)
              # Reschedule with exponential backoff
              backoff = (2**[execution_log.attempts || 1, 5].min).seconds

              self.class
                .set(wait: backoff)
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
              metadata: execution_log.metadata.merge("result" => true)
            )
            return true
          end

          # Check for timeout
          metadata = execution_log.metadata
          if Time.current > metadata["timeout_at"]
            execution_log.update!(
              state: :failed,
              metadata: metadata.merge("result" => nil)
            )
            Rails.logger.warn { "Timeout reached for condition #{condition}. Condition not met within the timeout period." }
            raise WaitConditionNotMet, "Condition not met within timeout period"
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
