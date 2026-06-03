module ChronoForge
  module Executor
    class Error < StandardError; end

    class ExecutionFailedError < Error; end

    class ExecutionFlowControl < Error; end

    class HaltExecutionFlow < ExecutionFlowControl; end

    class NotExecutableError < Error; end

    class WorkflowNotRetryableError < NotExecutableError; end

    class InvalidStepName < NotExecutableError; end

    # "$" separates the segments of a step name (e.g. "durably_repeat$name$ts").
    # User-supplied names/methods must not contain it.
    STEP_NAME_DELIMITER = "$"

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
        def retry_now(key, **)
          perform_now(key, retry_workflow: true, **)
        end

        # Add retry_later class method that calls perform_later with retry_workflow: true
        def retry_later(key, **)
          perform_later(key, retry_workflow: true, **)
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
      # SELECT-first: on every resume (the common case) the workflow already
      # exists, so a plain lookup avoids an INSERT that would fail on the unique
      # [job_class, key] index. create_or_find_by! is only reached on first-ever
      # creation, where it also handles a concurrent insert race safely.
      @workflow = Workflow.find_by(job_class: self.class.to_s, key: key) ||
        Workflow.create_or_find_by!(job_class: self.class.to_s, key: key) do |workflow|
          workflow.options = options
          workflow.kwargs = kwargs
          workflow.started_at = Time.current
        end
    end

    def setup_context!
      @context = Context.new(workflow)
    end

    # Idempotent, SELECT-first execution-log lookup.
    #
    # The engine replays the whole workflow body on every resume, so each durable
    # step is looked up again every pass. A plain create_or_find_by! would INSERT
    # first and fail on the unique index for the (overwhelmingly common) case
    # where the step already exists — turning every replayed step into a wasted
    # INSERT plus a burned sequence value. Looking up first means replays cost a
    # single indexed SELECT.
    #
    # All lookups are by exact step_name (no method ever scans a workflow's logs),
    # so a per-step lookup is also the right shape for durably_repeat workflows,
    # which accumulate unbounded repetition logs: we touch only the rows we need,
    # never the whole set. create_or_find_by! is used only on a miss, keeping
    # creation safe if a lock takeover ever lets two executors race.
    def find_or_create_execution_log!(step_name, &)
      ExecutionLog.find_by(workflow: @workflow, step_name: step_name) ||
        ExecutionLog.create_or_find_by!(workflow: @workflow, step_name: step_name, &)
    end

    # Guards the user-supplied portion of a step name (a custom name, method, or
    # condition). The "$" separator is reserved for the framework's own segment
    # structure, so a user value containing it would make step names ambiguous
    # and corrupt the cleanup logic that parses them.
    def validate_step_name_segment!(segment)
      return unless segment.to_s.include?(STEP_NAME_DELIMITER)

      raise InvalidStepName,
        "ChronoForge step name may not contain '#{STEP_NAME_DELIMITER}' (reserved separator): #{segment.inspect}"
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
