module ChronoForge
  module Executor
    module Methods
      module DurablyRepeat
        # Schedules a method to be called repeatedly at specified intervals until a condition is met.
        #
        # This method provides durable, idempotent periodic task execution with automatic catch-up
        # for missed executions using timeout-based fast-forwarding. Each repetition gets its own
        # execution log, ensuring proper tracking and retry behavior.
        #
        # @param method [Symbol] The name of the instance method to execute repeatedly.
        #   The method can optionally accept the scheduled execution time as its first argument.
        # @param every [ActiveSupport::Duration] The interval between executions (e.g., 3.days, 1.hour)
        # @param till [Symbol, Proc] The condition to check for stopping repetition. Should return
        #   true when repetition should stop. Can be a symbol for instance methods or a callable.
        # @param start_at [Time, nil] When to start the periodic task. Defaults to coordination_log.created_at + every
        # @param max_attempts [Integer] Maximum retry attempts per individual execution (default: 3)
        # @param timeout [ActiveSupport::Duration] How long after scheduled time an execution is
        #   considered stale and skipped (default: 1.hour). This enables catch-up behavior.
        # @param on_error [Symbol] How to handle repetition failures after max_attempts. Options:
        #   - :continue (default): Log failure and continue with next scheduled execution
        #   - :fail_workflow: Raise ExecutionFailedError to fail the entire workflow
        # @param name [String, nil] Custom name for the periodic task. Defaults to method name.
        #   Used to create unique step names for execution logs.
        #
        # @return [nil]
        #
        # @example Basic usage
        #   durably_repeat :send_reminder_email, every: 3.days, till: :user_onboarded?
        #
        # @example Method with scheduled execution time parameter
        #   def send_reminder_email(next_execution_at)
        #     # Can access the scheduled execution time
        #     lateness = Time.current - next_execution_at
        #     Rails.logger.info "Email scheduled for #{next_execution_at}, running #{lateness.to_i}s late"
        #     UserMailer.reminder_email(user_id, scheduled_for: next_execution_at).deliver_now
        #   end
        #
        #   durably_repeat :send_reminder_email, every: 3.days, till: :user_onboarded?
        #
        # @example Resilient background task (default)
        #   durably_repeat :cleanup_temp_files,
        #     every: 1.day,
        #     till: :cleanup_complete?,
        #     on_error: :continue
        #
        # @example Critical task that should fail workflow on error
        #   durably_repeat :process_payments,
        #     every: 1.hour,
        #     till: :all_payments_processed?,
        #     on_error: :fail_workflow
        #
        # @example Advanced usage with all options
        #   def generate_daily_report(scheduled_time)
        #     report_date = scheduled_time.to_date
        #     DailyReportService.new(date: report_date).generate
        #   end
        #
        #   durably_repeat :generate_daily_report,
        #     every: 1.day,
        #     till: :reports_complete?,
        #     start_at: Date.tomorrow.beginning_of_day,
        #     max_attempts: 5,
        #     timeout: 2.hours,
        #     on_error: :fail_workflow,
        #     name: "daily_reports"
        #
        # == Behavior
        #
        # === Method Parameters
        # Your periodic method can optionally receive the scheduled execution time:
        # - Method with no parameters: `def my_task; end` - called as `my_task()`
        # - Method with parameter: `def my_task(next_execution_at); end` - called as `my_task(scheduled_time)`
        #
        # This allows methods to:
        # - Log lateness/timing information
        # - Perform time-based calculations
        # - Include scheduled time in notifications
        # - Generate reports for specific time periods
        #
        # === Idempotency
        # Each execution gets a unique step name based on the scheduled execution time, ensuring
        # that workflow replays don't create duplicate tasks.
        #
        # === Catch-up Mechanism
        # If a workflow is paused and resumes later, the timeout parameter handles catch-up:
        # - Executions older than `timeout` are automatically skipped
        # - The periodic schedule integrity is maintained
        # - Eventually reaches current/future execution times
        #
        # === Error Handling
        # - Individual execution failures are retried up to `max_attempts` with exponential backoff
        # - After max attempts, behavior depends on `on_error` parameter:
        #   - `:continue`: Failed execution is logged, next execution is scheduled
        #   - `:fail_workflow`: ExecutionFailedError is raised, failing the entire workflow
        # - Timeouts are not considered errors and always continue to the next execution
        #
        # === Execution Logs
        # Creates two types of execution logs:
        # - Coordination log: `durably_repeat$#{name}` - tracks overall periodic task state
        # - Repetition logs: `durably_repeat$#{name}$#{timestamp}` - tracks individual executions
        #
        def durably_repeat(method, every:, till:, start_at: nil, max_attempts: 3, timeout: 1.hour, on_error: :continue, name: nil)
          step_name = "durably_repeat$#{name || method}"

          # Get or create the main coordination log for this periodic task
          coordination_log = ExecutionLog.create_or_find_by!(
            workflow: @workflow,
            step_name: step_name
          ) do |log|
            log.started_at = Time.current
            log.metadata = {last_execution_at: nil}
          end

          # Return if already completed
          return if coordination_log.completed?

          # Update coordination log attempt tracking
          coordination_log.update!(
            attempts: coordination_log.attempts + 1,
            last_executed_at: Time.current
          )

          # Check if we should stop repeating
          condition_met = if till.is_a?(Symbol)
            send(till)
          else
            till.call(context)
          end
          if condition_met
            coordination_log.update!(
              state: :completed,
              completed_at: Time.current
            )
            return
          end

          # Calculate next execution time
          metadata = coordination_log.metadata
          last_execution_at = metadata["last_execution_at"] ? Time.parse(metadata["last_execution_at"]) : nil

          next_execution_at = if last_execution_at
            last_execution_at + every
          elsif start_at
            start_at
          else
            coordination_log.created_at + every
          end

          execute_or_schedule_repetition(method, coordination_log, next_execution_at, every, max_attempts, timeout, on_error)
          nil
        end

        private

        def execute_or_schedule_repetition(method, coordination_log, next_execution_at, every, max_attempts, timeout, on_error)
          step_name = "#{coordination_log.step_name}$#{next_execution_at.to_i}"

          # Create execution log for this specific repetition
          repetition_log = ExecutionLog.create_or_find_by!(
            workflow: @workflow,
            step_name: step_name
          ) do |log|
            log.started_at = Time.current
            log.metadata = {
              scheduled_for: next_execution_at,
              timeout_at: next_execution_at + timeout,
              parent_id: coordination_log.id
            }
          end

          # Return if this repetition is already completed
          return if repetition_log.completed?

          # Update execution log with attempt
          repetition_log.update!(
            attempts: repetition_log.attempts + 1,
            last_executed_at: Time.current
          )

          # Check if it's time to execute this repetition
          if next_execution_at <= Time.current
            execute_repetition_now(method, repetition_log, coordination_log, next_execution_at, every, max_attempts, timeout, on_error)
          else
            schedule_repetition_for_later(repetition_log, next_execution_at)
          end
        end

        def schedule_repetition_for_later(repetition_log, next_execution_at)
          # Calculate delay until execution time
          delay = [next_execution_at - Time.current, 0].max.seconds

          # Schedule the workflow to run at the specified time
          self.class
            .set(wait: delay)
            .perform_later(@workflow.key)

          # Halt current execution until scheduled time
          halt_execution!
        end

        def execute_repetition_now(method, repetition_log, coordination_log, execution_time, every, max_attempts, timeout, on_error)
          # Check for timeout
          if Time.current > repetition_log.metadata["timeout_at"]
            repetition_log.update!(
              state: :failed,
              error_message: "Execution timed out",
              error_class: "TimeoutError"
            )

            # Timeouts are part of the catch-up mechanism, always continue to next execution
            schedule_next_execution_after_completion(coordination_log, execution_time, every)
            return
          end

          execute_periodic_method(method, execution_time)
          repetition_log.update!(
            state: :completed,
            completed_at: Time.current
          )

          schedule_next_execution_after_completion(coordination_log, execution_time, every)
        rescue HaltExecutionFlow
          raise
        rescue => e
          # Log the error
          Rails.logger.error { "Error in periodic task #{method}: #{e.message}" }
          self.class::ExecutionTracker.track_error(@workflow, e)

          # Handle retry logic for this specific repetition
          if repetition_log.attempts < max_attempts
            # Reschedule this same repetition with exponential backoff
            backoff = (2**[repetition_log.attempts, 5].min).seconds

            self.class
              .set(wait: backoff)
              .perform_later(@workflow.key)

            # Halt current execution
            halt_execution!
          else
            # Max attempts reached for this repetition
            repetition_log.update!(
              state: :failed,
              error_message: e.message,
              error_class: e.class.name
            )

            # Handle failure based on on_error setting
            if on_error == :fail_workflow
              raise ExecutionFailedError, "Periodic task #{method} failed after #{max_attempts} attempts: #{e.message}"
            else
              # Continue with next execution despite this failure
              schedule_next_execution_after_completion(coordination_log, execution_time, every)
            end
          end
        end

        def execute_periodic_method(method, next_execution_at)
          # Check if the method accepts an argument by looking at its arity
          method_obj = self.method(method)

          if method_obj.arity != 0
            # Method accepts arguments (either required or optional), pass next_execution_at
            send(method, next_execution_at)
          else
            # Method takes no arguments
            send(method)
          end
        end

        def schedule_next_execution_after_completion(coordination_log, current_execution_time, every)
          # Update coordination log and schedule next
          coordination_log.update!(
            metadata: coordination_log.metadata.merge(
              "last_execution_at" => current_execution_time.iso8601
            ),
            last_executed_at: Time.current
          )

          # Calculate next execution time
          next_execution_time = current_execution_time + every

          # Calculate delay until next execution
          delay = [next_execution_time - Time.current, 0].max.seconds

          # Schedule the workflow to run for the next periodic execution
          self.class
            .set(wait: delay)
            .perform_later(@workflow.key)

          # Halt current execution
          halt_execution!
        end
      end
    end
  end
end
