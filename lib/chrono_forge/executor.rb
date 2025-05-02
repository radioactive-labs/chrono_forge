module ChronoForge
  module Executor
    class Error < StandardError; end

    class ExecutionFailedError < Error; end

    class ExecutionFlowControl < Error; end

    class HaltExecutionFlow < ExecutionFlowControl; end

    class NotExecutableError < Error; end

    class WorkflowNotRetryableError < NotExecutableError; end

    include Methods

    # Add class methods
    def self.prepended(base)
      class << base
        # Enforce expected signature for perform_now with key as first arg and keywords after
        def perform_now(key, **kwargs)
          if !key.is_a?(String)
            raise ArgumentError, "Workflow key must be a string as the first argument"
          end
          super
        end

        # Enforce expected signature for perform_later with key as first arg and keywords after
        def perform_later(key, **kwargs)
          if !key.is_a?(String)
            raise ArgumentError, "Workflow key must be a string as the first argument"
          end
          super
        end

        # Add retry_now class method that calls perform_now with retry_workflow: true
        def retry_now(key, **kwargs)
          perform_now(key, retry_workflow: true, **kwargs)
        end

        # Add retry_later class method that calls perform_later with retry_workflow: true
        def retry_later(key, **kwargs)
          perform_later(key, retry_workflow: true, **kwargs)
        end
      end
    end

    def perform(key, attempt: 0, retry_workflow: false, options: {}, **kwargs)
      # Prevent excessive retries
      if attempt >= self.class::RetryStrategy.max_attempts
        Rails.logger.error { "ChronoForge:#{self.class} max attempts reached for job workflow(#{key})" }
        return
      end

      # Find or create workflow instance
      setup_workflow!(key, options, kwargs)

      # Handle retry parameter - unlock and continue execution
      retry_workflow! if retry_workflow

      # Track if we acquired the lock
      lock_acquired = false

      begin
        # Acquire lock with advanced concurrency protection
        @workflow = self.class::LockStrategy.acquire_lock(job_id, workflow, max_duration: max_duration)
        lock_acquired = true

        # Setup context
        setup_context!

        # Execute core job logic
        super(**workflow.kwargs.symbolize_keys)

        # Mark as complete
        complete_workflow!
      rescue ExecutionFailedError => e
        Rails.logger.error { "ChronoForge:#{self.class}(#{key}) step execution failed" }
        self.class::ExecutionTracker.track_error(workflow, e)
        workflow.stalled!
        nil
      rescue HaltExecutionFlow
        # Halt execution
        Rails.logger.debug { "ChronoForge:#{self.class}(#{key}) execution halted" }
        nil
      rescue ConcurrentExecutionError
        # Graceful handling of concurrent execution
        Rails.logger.warn { "ChronoForge:#{self.class}(#{key}) concurrent execution detected" }
        nil
      rescue NotExecutableError
        raise
      rescue => e
        Rails.logger.error { "ChronoForge:#{self.class}(#{key}) workflow execution failed" }
        error_log = self.class::ExecutionTracker.track_error(workflow, e)

        # Retry if applicable
        if should_retry?(e, attempt)
          self.class::RetryStrategy.schedule_retry(workflow, attempt: attempt)
        else
          fail_workflow! error_log
        end
      ensure
        if lock_acquired # Only release lock if we acquired it
          context.save!
          self.class::LockStrategy.release_lock(job_id, workflow)
        end
      end
    end

    private

    def setup_workflow!(key, options, kwargs)
      @workflow = Workflow.create_or_find_by!(job_class: self.class.to_s, key: key) do |workflow|
        workflow.options = options
        workflow.kwargs = kwargs
        workflow.started_at = Time.current
      end
    end

    def setup_context!
      @context = Context.new(workflow)
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
