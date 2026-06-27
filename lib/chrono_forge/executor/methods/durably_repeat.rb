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
        # @param retry_policy [RetryPolicy, nil] Per-call retry policy for an individual
        #   execution. When nil, uses the class-level `retry_policy` default, then the
        #   step built-in (RetryPolicy.step_default: 3 attempts, backoff capped at 30s).
        # @param timeout [ActiveSupport::Duration] How long after scheduled time an execution is
        #   considered stale and skipped (default: 1.hour). This enables catch-up behavior.
        # @param on_error [Symbol] How to handle repetition failures after the policy's max_attempts. Options:
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
        #     retry_policy: RetryPolicy.new(max_attempts: 5),
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
        # - Individual execution failures are retried per the resolved RetryPolicy
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
        def durably_repeat(method, every:, till:, start_at: nil, retry_policy: nil, timeout: 1.hour, on_error: :continue, name: nil)
          policy = step_retry_policy(retry_policy)
          validate_step_name_segment!(name || method)
          step_name = "durably_repeat$#{name || method}"

          # Get or create the main coordination log for this periodic task
          coordination_log = find_or_create_execution_log!(step_name) do |log|
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

          next_execution_at = fast_forward_expired_prefix(coordination_log, next_execution_at, every, timeout)

          execute_or_schedule_repetition(method, coordination_log, next_execution_at, every, policy, timeout, on_error)
          nil
        end

        private

        # Catch-up fast-forward. A tick `t` is expired (its work is skipped) iff
        # `Time.current > t + timeout`, i.e. `t < now - timeout`. Rather than
        # walking one zero-delay job per expired tick, jump straight to the first
        # non-expired tick on the same grid (see #advance_to_first_valid_tick).
        #
        # Anchoring the arithmetic on `next_execution_at` (already on the canonical
        # grid: start_at / created_at+every / last_execution_at+every all land on
        # it, because last_execution_at stores the *scheduled* time, not wall-clock)
        # keeps the result exactly on the grid — no drift, for fixed AND calendar
        # intervals.
        #
        # Returns `next_execution_at` unchanged when nothing is expired. Otherwise
        # advances the coordination log's last_execution_at so a replay recomputes
        # the same first tick, and writes ONE summary ExecutionLog for the whole
        # skipped prefix (no per-tick timeout rows).
        def fast_forward_expired_prefix(coordination_log, next_execution_at, every, timeout)
          cutoff = Time.current - timeout
          return next_execution_at if next_execution_at >= cutoff

          first_valid, n = advance_to_first_valid_tick(next_execution_at, every, cutoff)
          last_skipped = first_valid - every

          Rails.logger.info {
            "ChronoForge:#{self.class}(#{@workflow.key}) durably_repeat fast-forwarded " \
            "#{n} expired tick(s) to #{first_valid.iso8601}"
          }

          # Single summary row for the skipped prefix, on the last skipped grid
          # tick. This never collides with the first_valid repetition row, but it
          # CAN reuse a prior cycle's pending repetition log at the same tick
          # (e.g. a tick that was scheduled-for-later then later fast-forwarded
          # over). Write the metadata in the update! so the fast_forward summary
          # fields are present whether the row is newly created or reused.
          summary_step = "#{coordination_log.step_name}$#{last_skipped.to_i}"
          summary_log = find_or_create_execution_log!(summary_step) do |log|
            log.started_at = Time.current
          end
          summary_log.update!(
            state: :failed,
            error_class: "TimeoutError",
            error_message: "Fast-forwarded #{n} expired tick(s)",
            completed_at: Time.current,
            metadata: (summary_log.metadata || {}).merge(
              "fast_forwarded" => n,
              "from" => next_execution_at.iso8601,
              "to" => last_skipped.iso8601,
              "scheduled_for" => last_skipped.iso8601,
              "timeout_at" => (last_skipped + timeout).iso8601,
              "parent_id" => coordination_log.id
            )
          )

          # Record progress: a replay recomputes naive_next = last + every = first_valid.
          # Use .iso8601 (second precision) to match the existing last_execution_at
          # format so resumed pre-existing workflows keep the same on-disk grid.
          coordination_log.update!(
            metadata: coordination_log.metadata.merge("last_execution_at" => last_skipped.iso8601)
          )

          first_valid
        end

        # Walk the canonical grid from `from` to the first tick at/after `cutoff`,
        # returning [first_valid_tick, ticks_skipped].
        #
        # The split is at one day, which is exactly where ActiveSupport switches
        # arithmetic:
        #
        # - Sub-day intervals (hours/minutes/seconds) are absolute (seconds-based):
        #   `from + n*every` is mathematically exact, no DST or clamping. These are
        #   also the only intervals whose missed-tick count can explode (1.second
        #   dormant a year ≈ 31M ticks), so we MUST jump in closed form.
        #
        # - Day-and-larger intervals go through calendar arithmetic (a "day" across
        #   DST is 23h/25h; months clamp at end-of-month), so `from + n*every` can
        #   drift off the grid (Jan 31 + 3.months = Apr 30, but stepping +1.month
        #   three times lands on Apr 28). Their count over any realistic dormancy is
        #   small (daily over a decade ≈ 3650), so we step the grid exactly.
        def advance_to_first_valid_tick(from, every, cutoff)
          if every < 1.day
            n = ((cutoff - from) / every.to_f).ceil
            [from + (n * every), n]
          else
            tick = from
            n = 0
            while tick < cutoff
              tick += every
              n += 1
            end
            [tick, n]
          end
        end

        def execute_or_schedule_repetition(method, coordination_log, next_execution_at, every, policy, timeout, on_error)
          step_name = "#{coordination_log.step_name}$#{next_execution_at.to_i}"

          # Create execution log for this specific repetition
          repetition_log = find_or_create_execution_log!(step_name) do |log|
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
            execute_repetition_now(method, repetition_log, coordination_log, next_execution_at, every, policy, timeout, on_error)
          else
            schedule_repetition_for_later(repetition_log, next_execution_at)
          end
        end

        def schedule_repetition_for_later(repetition_log, next_execution_at)
          # Calculate delay until execution time
          delay = [next_execution_at - Time.current, 0].max.seconds

          # Schedule the workflow to run at the specified time (published after release).
          enqueue_continuation(wait: delay)

          # Halt current execution until scheduled time
          halt_execution!
        end

        def execute_repetition_now(method, repetition_log, coordination_log, execution_time, every, policy, timeout, on_error)
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
          self.class::ExecutionTracker.track_error(@workflow, e, execution_log: repetition_log)

          # Handle retry logic for this specific repetition
          backoff = policy.retry_backoff(e, attempts: repetition_log.attempts) do |policy_key|
            bump_retry_count!(repetition_log, policy_key)
          end
          if backoff
            # Reschedule this same repetition with the policy's backoff (after release).
            enqueue_continuation(wait: backoff)

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
              raise ExecutionFailedError, "Periodic task #{method} failed after #{repetition_log.attempts} attempts: #{e.message}"
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

          # Schedule the next periodic execution (published after lock release).
          enqueue_continuation(wait: delay)

          # Halt current execution
          halt_execution!
        end
      end
    end
  end
end
