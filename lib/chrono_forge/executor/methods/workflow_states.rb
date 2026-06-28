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
          enforce_branch_joins!

          # Completion is two writes with no external side effect between them: the
          # workflow → :completed transition and the (born-completed) marker. Batch
          # them in one transaction so a trivial child pays a single commit here,
          # and write the marker in its terminal state in a single INSERT.
          execution_log = nil
          begin
            ActiveRecord::Base.transaction do
              workflow.completed_at = Time.current
              workflow.completed!
              execution_log = create_completed_execution_log!("$workflow_completion$")
            end

            # Return the execution log for tracking
            execution_log
          rescue => e
            # The transaction rolled back (so the marker may be gone too). Re-find
            # or recreate it and record the failure for observability, then re-raise.
            # The workflow stays not-completed, so a resume retries completion.
            log = find_or_create_execution_log!("$workflow_completion$") do |l|
              l.started_at = Time.current
            end
            log.update!(state: :failed, error_message: e.message, error_class: e.class.name)
            raise
          end
        end

        # Every branch must be joined: automerge branches join inline at their
        # block's close (removing themselves from @open_branches); explicitly
        # awaited branches are removed by merge_branches. Anything still in
        # @open_branches here was opened but never joined — fail fast.
        def enforce_branch_joins!
          leftover = (@open_branches || {}).keys
          return if leftover.empty?

          raise UnmergedBranchError,
            "branch(es) #{leftover.join(", ")} were opened but never merged. " \
            "Add `merge_branches #{leftover.map { |n| ":#{n}" }.join(", ")}` " \
            "or open with `branch(..., automerge: true)`."
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
          step_name = "$workflow_failure$#{error_log.id}"

          # Mirror complete_workflow!: the workflow → :failed transition and the
          # (born-completed) failure marker are batched in one transaction, and the
          # marker is written in its terminal state in a single INSERT.
          execution_log = nil
          begin
            ActiveRecord::Base.transaction do
              workflow.failed!
              execution_log = create_completed_execution_log!(step_name) do |log|
                log.metadata = {error_log_id: error_log.id}
              end
            end

            # Return the execution log for tracking
            execution_log
          rescue => e
            # The transaction rolled back; re-find/recreate the marker and record
            # the failure for observability, then re-raise.
            log = find_or_create_execution_log!(step_name) do |l|
              l.started_at = Time.current
              l.metadata = {error_log_id: error_log.id}
            end
            log.update!(state: :failed, error_message: e.message, error_class: e.class.name)
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
          # Authoritative check at execution time (the record-level retry methods
          # also check up front, but state may have changed since enqueue).
          workflow.ensure_retryable!

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
