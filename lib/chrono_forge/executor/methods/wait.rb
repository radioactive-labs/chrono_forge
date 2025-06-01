module ChronoForge
  module Executor
    module Methods
      module Wait
        # Pauses workflow execution for a specified duration.
        #
        # This method provides durable waiting that persists across workflow restarts and
        # system interruptions. The wait duration and completion state are tracked in
        # execution logs, ensuring that workflows can resume properly after delays.
        #
        # @param duration [ActiveSupport::Duration] How long to wait (e.g., 5.minutes, 2.hours, 1.day)
        # @param name [String] A unique name for this wait step, used for tracking and idempotency
        #
        # @return [nil]
        #
        # @example Basic usage
        #   wait 30.minutes, "cool_down_period"
        #
        # @example Waiting between API calls
        #   wait 5.seconds, "rate_limit_delay"
        #
        # @example Daily processing delay
        #   wait 1.day, "daily_batch_interval"
        #
        # @example Workflow with multiple wait steps
        #   def process_user_onboarding
        #     send_welcome_email
        #     wait 1.hour, "welcome_email_delay"
        #
        #     send_tutorial_email
        #     wait 1.day, "tutorial_followup_delay"
        #
        #     send_feedback_request
        #   end
        #
        # @example Waiting for external system processing
        #   def handle_payment_processing
        #     initiate_payment_request
        #
        #     # Give payment processor time to handle the request
        #     wait 10.minutes, "payment_processing_window"
        #
        #     check_payment_status
        #   end
        #
        # == Behavior
        #
        # === Duration Handling
        # - Accepts any ActiveSupport::Duration (seconds, minutes, hours, days, etc.)
        # - Wait time is calculated from the first execution attempt
        # - Completion is checked against the originally scheduled end time
        #
        # === Idempotency
        # - Each wait step must have a unique name within the workflow
        # - If workflow is replayed after the wait period has passed, the step is skipped
        # - Wait periods are not recalculated on workflow restarts
        #
        # === Resumability
        # - Wait state is persisted in execution logs with target end time
        # - Workflows can be stopped and restarted without affecting wait behavior
        # - System restarts don't reset or extend wait periods
        # - Scheduled execution resumes automatically when wait period completes
        #
        # === Scheduling
        # - Uses background job scheduling to resume workflow after wait period
        # - Halts current workflow execution until scheduled time
        # - Automatically reschedules if workflow is replayed before wait completion
        #
        # === Execution Logs
        # Creates execution log with step name: `wait$#{name}`
        # - Stores target end time in metadata as "wait_until"
        # - Tracks attempt count and execution times
        # - Marks as completed when wait period has elapsed
        #
        def wait(duration, name)
          step_name = "wait$#{name}"
          # Find or create execution log
          execution_log = ExecutionLog.create_or_find_by!(
            workflow: @workflow,
            step_name: step_name
          ) do |log|
            log.started_at = Time.current
            log.metadata = {
              wait_until: duration.from_now
            }
          end

          # Return if already completed
          return if execution_log.completed?

          # Check if wait period has passed
          if Time.current >= Time.parse(execution_log.metadata["wait_until"])
            execution_log.update!(
              attempts: execution_log.attempts + 1,
              state: :completed,
              completed_at: Time.current,
              last_executed_at: Time.current
            )
            return
          end

          execution_log.update!(
            attempts: execution_log.attempts + 1,
            last_executed_at: Time.current
          )

          # Reschedule the job
          self.class
            .set(wait: duration)
            .perform_later(@workflow.key)

          # Halt current execution
          halt_execution!
        end
      end
    end
  end
end
