module ChronoForge
  module Executor
    class Error < StandardError; end

    class ExecutionFailedError < Error; end

    class ExecutionFlowControl < Error; end

    class HaltExecutionFlow < ExecutionFlowControl; end

    class NotExecutableError < Error; end

    include Methods

    def perform(key, attempt: 0, options: {}, **kwargs)
      # Prevent excessive retries
      if attempt >= self.class::RetryStrategy.max_attempts
        Rails.logger.error { "ChronoForge:#{self.class} max attempts reached for job workflow(#{key})" }
        return
      end

      # Find or create job with comprehensive tracking
      setup_workflow(key, options, kwargs)

      # Track if we acquired the lock
      lock_acquired = false

      begin
        # Raise error if workflow cannot be executed
        unless workflow.executable?
          raise NotExecutableError, "#{self.class}(#{key}) is not in an executable state"
        end

        # Acquire lock with advanced concurrency protection
        self.class::LockStrategy.acquire_lock(job_id, workflow, max_duration: max_duration)
        lock_acquired = true

        # Execute core job logic
        super(**workflow.kwargs.symbolize_keys)

        # Mark as complete
        complete_workflow!
      rescue ExecutionFailedError => e
        Rails.logger.error { "ChronoForge:#{self.class} execution step failed for workflow(#{key})" }
        self.class::ExecutionTracker.track_error(workflow, e)
        workflow.stalled!
        nil
      rescue HaltExecutionFlow
        # Halt execution
        Rails.logger.debug { "ChronoForge:#{self.class} execution halted for workflow(#{key})" }
        nil
      rescue ConcurrentExecutionError
        # Graceful handling of concurrent execution
        Rails.logger.warn { "ChronoForge:#{self.class} concurrent execution detected for job #{key}" }
        nil
      rescue NotExecutableError
        raise
      rescue => e
        Rails.logger.error { "ChronoForge:#{self.class} an error occurred during execution of workflow(#{key})" }
        error_log = self.class::ExecutionTracker.track_error(workflow, e)

        # Retry if applicable
        if should_retry?(e, attempt)
          self.class::RetryStrategy.schedule_retry(workflow, attempt: attempt)
        else
          fail_workflow! error_log
        end
      ensure
        # Only release lock if we acquired it
        if lock_acquired
          context.save!
          self.class::LockStrategy.release_lock(job_id, workflow)
        end
      end
    end

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
        # Log any completion errors
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
        step_name: "$workflow_failure$"
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
        # Log any completion errors
        execution_log.update!(
          state: :failed,
          error_message: e.message,
          error_class: e.class.name
        )
        raise
      end
    end

    def setup_workflow(key, options, kwargs)
      @workflow = find_workflow(key, options, kwargs)
      @context = Context.new(@workflow)
    end

    def find_workflow(key, options, kwargs)
      Workflow.create_or_find_by!(job_class: self.class.to_s, key: key) do |workflow|
        workflow.options = options
        workflow.kwargs = kwargs
        workflow.started_at = Time.current
      end
    end

    def should_retry?(error, attempt_count)
      attempt_count < 3
    end

    def halt_execution!
      raise HaltExecutionFlow
    end

    def workflow
      @workflow
    end

    def context
      @context
    end

    def max_duration
      10.minutes
    end
  end
end
