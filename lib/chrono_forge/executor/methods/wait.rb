module ChronoForge
  module Executor
    module Methods
      module Wait
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
