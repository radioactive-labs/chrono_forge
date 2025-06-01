module ChronoForge
  module Executor
    module Methods
      module WorkflowStates
        private

        # Marks a workflow as successfully completed.
        #
        # This method provides durable workflow completion tracking with proper state
        # management and execution logging. It ensures the workflow state is updated
        # atomically and any completion side effects are properly recorded.
        #
        # @return [ExecutionLog] The execution log created for the completion event
        #
        # @raise [StandardError] If workflow completion fails for any reason
        #
        # @example Basic usage (typically called automatically)
        #   complete_workflow!
        #
        # @example In a workflow executor
        #   def execute
        #     process_all_steps
        #     complete_workflow! # Called when all steps succeed
        #   rescue => e
        #     fail_workflow!(error_log)
        #   end
        #
        # == Behavior
        #
        # === State Management
        # - Sets workflow.completed_at to current timestamp
        # - Transitions workflow state to 'completed'
        # - Updates are atomic to prevent race conditions
        #
        # === Execution Logging
        # - Creates execution log with step name: "$workflow_completion$"
        # - Tracks completion attempt and timing information
        # - Marks execution log as completed when successful
        # - Records any errors that occur during completion
        #
        # === Error Handling
        # - Any exceptions during completion are caught and logged
        # - Execution log is marked as failed with error details
        # - Original exception is re-raised after logging
        #
        # === Idempotency
        # - Uses create_or_find_by to prevent duplicate completion logs
        # - Safe to call multiple times without side effects
        #
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

        # Marks a workflow as failed due to an unrecoverable error.
        #
        # This method provides durable workflow failure tracking with proper state
        # management and error context preservation. It ensures the workflow state
        # is updated atomically and failure details are properly recorded.
        #
        # @param error_log [ErrorLog] The error log associated with the failure
        #
        # @return [ExecutionLog] The execution log created for the failure event
        #
        # @raise [StandardError] If workflow failure processing fails for any reason
        #
        # @example Basic usage
        #   begin
        #     risky_operation
        #   rescue => e
        #     error_log = log_error(e)
        #     fail_workflow!(error_log)
        #   end
        #
        # @example In a workflow executor with error handling
        #   def execute
        #     process_all_steps
        #     complete_workflow!
        #   rescue ExecutionFailedError => e
        #     error_log = ErrorLog.create!(workflow: @workflow, error: e)
        #     fail_workflow!(error_log)
        #   end
        #
        # == Behavior
        #
        # === State Management
        # - Transitions workflow state to 'failed'
        # - Updates are atomic to prevent race conditions
        # - Preserves relationship to causing error log
        #
        # === Execution Logging
        # - Creates execution log with step name: "$workflow_failure$#{error_log.id}"
        # - Links to the error_log that caused the failure via metadata
        # - Tracks failure processing attempt and timing information
        # - Marks execution log as completed when failure processing succeeds
        #
        # === Error Context
        # - Maintains reference to original error through error_log parameter
        # - Enables debugging and failure analysis through error log relationship
        # - Preserves error details for workflow monitoring and alerting
        #
        # === Error Handling
        # - Any exceptions during failure processing are caught and logged
        # - Execution log is marked as failed with error details
        # - Original exception is re-raised after logging
        #
        # === Idempotency
        # - Uses create_or_find_by to prevent duplicate failure logs
        # - Safe to call multiple times with same error_log
        #
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

        # Retries a stalled or failed workflow by releasing locks and resetting state.
        #
        # This method provides durable workflow retry functionality with proper
        # state validation and lock management. It ensures that only eligible
        # workflows can be retried and tracks retry attempts for monitoring.
        #
        # @return [ExecutionLog] The execution log created for the retry event
        #
        # @raise [WorkflowNotRetryableError] If workflow is not in a retryable state
        # @raise [StandardError] If retry processing fails for any reason
        #
        # @example Basic usage
        #   workflow = Workflow.find_by(key: 'stuck-workflow-123')
        #   workflow.retry_workflow! if workflow.stalled?
        #
        # @example With error handling
        #   begin
        #     retry_workflow!
        #     Rails.logger.info "Workflow retry initiated successfully"
        #   rescue WorkflowNotRetryableError => e
        #     Rails.logger.warn "Cannot retry workflow: #{e.message}"
        #   end
        #
        # @example In a monitoring system
        #   def retry_stalled_workflows
        #     Workflow.stalled.find_each do |workflow|
        #       begin
        #         workflow.retry_workflow!
        #       rescue WorkflowNotRetryableError
        #         # Skip non-retryable workflows
        #       end
        #     end
        #   end
        #
        # == Behavior
        #
        # === State Validation
        # - Only allows retry of workflows in 'stalled' or 'failed' states
        # - Raises WorkflowNotRetryableError for workflows in other states
        # - Prevents retry of running or completed workflows
        #
        # === Lock Management
        # - Forcibly releases any existing workflow locks using LockStrategy
        # - Enables workflow to be picked up by new executor instances
        # - Prevents deadlock situations during retry
        #
        # === Execution Logging
        # - Creates execution log with step name: "$workflow_retry$#{timestamp}"
        # - Records previous workflow state in metadata
        # - Tracks retry request timestamp and job_id
        # - Marks execution log as completed when retry succeeds
        #
        # === Retry Tracking
        # - Preserves historical context of what state triggered the retry
        # - Enables monitoring of retry frequency and patterns
        # - Helps diagnose recurring workflow issues
        #
        # === Error Handling
        # - Any exceptions during retry processing are caught and logged
        # - Execution log is marked as failed with error details
        # - Original exception is re-raised after logging
        #
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
