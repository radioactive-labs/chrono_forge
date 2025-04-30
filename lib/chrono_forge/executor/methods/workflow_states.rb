module ChronoForge
  module Executor
    module Methods
      module WorkflowStates
        private
        
        def complete_workflow!
          # Create an execution log for workflow completion
          execution_log = ExecutionLog.create_or_find_by!(
            workflow: workflow,
            step_name: "$workflow_completion$"
          ) do |log|
            log.started_at = Time.current
          end

          begin
            execution_log.update!(
              attempts: execution_log.attempts + 1,
              last_executed_at: Time.current
            )

            workflow.completed_at = Time.current
            workflow.completed!

            # Mark execution log as completed
            execution_log.update!(
              state: :completed,
              completed_at: Time.current
            )

            # Return the execution log for tracking
            execution_log
          rescue => e
            # Log any errors
            execution_log.update!(
              state: :failed,
              error_message: e.message,
              error_class: e.class.name
            )
            raise
          end
        end

        def fail_workflow!(error_log)
          # Create an execution log for workflow failure
          execution_log = ExecutionLog.create_or_find_by!(
            workflow: workflow,
            step_name: "$workflow_failure$#{error_log.id}"
          ) do |log|
            log.started_at = Time.current
            log.metadata = {
              error_log_id: error_log.id
            }
          end

          begin
            execution_log.update!(
              attempts: execution_log.attempts + 1,
              last_executed_at: Time.current
            )

            workflow.failed!

            # Mark execution log as completed
            execution_log.update!(
              state: :completed,
              completed_at: Time.current
            )

            # Return the execution log for tracking
            execution_log
          rescue => e
            # Log any errors
            execution_log.update!(
              state: :failed,
              error_message: e.message,
              error_class: e.class.name
            )
            raise
          end
        end

        def retry_workflow!
          # Check if the workflow is stalled or failed
          unless workflow.stalled? || workflow.failed?
            raise WorkflowNotRetryableError, "Cannot retry workflow(#{workflow.key}) in #{workflow.state} state. Only stalled or failed workflows can be retried."
          end

          # Create an execution log for workflow retry
          execution_log = ExecutionLog.create!(
            workflow: workflow,
            step_name: "$workflow_retry$#{Time.current.to_i}",
            started_at: Time.current,
            attempts: 1,
            last_executed_at: Time.current,
            metadata: {
              previous_state: workflow.state,
              requested_at: Time.current,
              job_id: job_id
            }
          )

          begin
            # Release any existing locks
            self.class::LockStrategy.release_lock(job_id, workflow, force: true)

            # Mark execution log as completed
            execution_log.update!(
              state: :completed,
              completed_at: Time.current
            )

            # Return the execution log for tracking
            execution_log
          rescue => e
            # Log any errors
            execution_log.update!(
              state: :failed,
              error_message: e.message,
              error_class: e.class.name
            )
            raise
          end
        end
      end
    end
  end
end
