module ChronoForge
  module Executor
    module Methods
      module ContinueIf
        # Waits until a specified condition becomes true, without any automatic polling or time-based checks.
        #
        # This method provides a durable pause state that can only be resumed by manually retrying
        # the workflow (typically triggered by external events like webhooks). Unlike wait_until,
        # this method does not automatically poll the condition - it simply evaluates the condition
        # once and either proceeds (if true) or halts execution (if false) until manually retried.
        #
        # @param condition [Symbol] The name of the instance method to evaluate as the condition.
        #   The method should return a truthy value when the condition is met.
        # @param name [String, nil] Optional custom name for this step. If not provided, uses the condition name.
        #   Useful for tracking multiple calls to the same condition or providing more descriptive names.
        #
        # @return [true] When the condition is met
        #
        # @example Basic usage
        #   continue_if :payment_confirmed?
        #
        # @example With custom name
        #   continue_if :payment_confirmed?, name: "stripe_payment_confirmation"
        #
        # @example Waiting for external webhook
        #   continue_if :webhook_received?
        #
        # @example Waiting for manual approval
        #   continue_if :approval_granted?
        #
        # @example Multiple continue_if with same condition but different names
        #   continue_if :external_system_ready?, name: "payment_system_ready"
        #   # ... other workflow steps ...
        #   continue_if :external_system_ready?, name: "inventory_system_ready"
        #
        # @example Complete workflow with manual continuation
        #   def perform(order_id:)
        #     @order_id = order_id
        #
        #     # Process initial order
        #     durably_execute :initialize_order
        #
        #     # Wait for external payment confirmation (webhook-driven)
        #     continue_if :payment_confirmed?, name: "stripe_webhook"
        #
        #     # Complete order processing
        #     durably_execute :complete_order
        #   end
        #
        #   private
        #
        #   def payment_confirmed?
        #     PaymentService.confirmed?(@order_id)
        #   end
        #
        #   # Later, when webhook arrives:
        #   # PaymentService.mark_confirmed(order_id)
        #   # OrderProcessingWorkflow.perform_later("order-#{order_id}", order_id: order_id)
        #
        # == Behavior
        #
        # === Condition Evaluation
        # The condition method is called once per workflow execution:
        # - If truthy, execution continues immediately
        # - If falsy, workflow execution halts until manually retried
        # - No automatic polling or retry attempts are made
        #
        # === Manual Retry Required
        # Unlike other wait states, continue_if requires external intervention:
        # - Call Workflow.perform_later(key, **kwargs) to continue the workflow
        # - Typically triggered by webhooks, background jobs, or manual intervention
        # - No timeout or automatic resumption
        #
        # === Error Handling
        # - Exceptions during condition evaluation cause workflow failure
        # - No automatic retry on condition evaluation errors
        # - Use try/catch in condition methods for error handling
        #
        # === Persistence and Resumability
        # - Wait state is persisted in execution logs
        # - Workflow can be stopped/restarted without losing wait progress
        # - Condition evaluation state persists across restarts
        # - Safe for system interruptions and deployments
        #
        # === Execution Logs
        # Creates execution log with step name: `continue_if$#{name || condition}`
        # - Tracks attempt count and execution times
        # - Records final result (true for success)
        #
        # === Use Cases
        # Perfect for workflows that depend on:
        # - External webhook notifications
        # - Manual approval processes
        # - File uploads or external processing completion
        # - Third-party system state changes
        # - User actions or form submissions
        #
        def continue_if(condition, name: nil)
          step_name = "continue_if$#{name || condition}"

          # Find or create execution log
          execution_log = ExecutionLog.create_or_find_by!(
            workflow: @workflow,
            step_name: step_name
          ) do |log|
            log.started_at = Time.current
            log.metadata = {
              condition: condition.to_s,
              name: name
            }
          end

          # Return if already completed
          if execution_log.completed?
            return execution_log.metadata["result"]
          end

          # Evaluate condition once
          begin
            execution_log.update!(
              attempts: execution_log.attempts + 1,
              last_executed_at: Time.current
            )

            condition_met = send(condition)
          rescue HaltExecutionFlow
            raise
          rescue => e
            # Log the error and fail the execution
            Rails.logger.error { "Error evaluating condition #{condition}: #{e.message}" }
            self.class::ExecutionTracker.track_error(workflow, e)

            execution_log.update!(
              state: :failed,
              error_message: e.message,
              error_class: e.class.name
            )
            raise ExecutionFailedError, "#{step_name} failed with an error: #{e.message}"
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

          # Condition not met - halt execution without scheduling any retry
          # Workflow will remain in idle state until manually retried
          Rails.logger.debug { "Condition not met for #{step_name}, workflow will wait for manual retry" }
          halt_execution!
        end
      end
    end
  end
end
