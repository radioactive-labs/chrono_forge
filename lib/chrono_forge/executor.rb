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
      # Class-wide default retry policy, inherited by subclasses. Set via the
      # `retry_policy` DSL below; nil means "use the per-site built-in default".
      base.class_attribute :default_retry_policy, instance_accessor: false, default: nil

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

        # Class-level DSL to set this workflow's default retry policy. Applies to
        # workflow-level retries and to steps without a per-call override.
        # Positional RetryPolicy objects build a composite (per-error budgets);
        # keyword options build a single RetryPolicy. The two forms are mutually
        # exclusive.
        def retry_policy(*policies, **opts)
          if policies.any? && opts.any?
            raise ArgumentError, "retry_policy takes either positional policies or keyword options, not both"
          end

          self.default_retry_policy =
            policies.any? ? RetryPolicy.compose(*policies) : RetryPolicy.new(**opts)
        end
      end
    end

    def perform(key, attempt: 0, retry_workflow: false, options: {}, **kwargs)
      # Safety net: prevent re-running a workflow whose attempts are exhausted
      # (e.g. a stale job left in the queue). The normal exhaustion path fails the
      # workflow from the rescue below before this is ever reached.
      policy = workflow_retry_policy
      if policy.max_attempts && attempt >= policy.max_attempts
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
      rescue ExecutionFailedError
        # The step that raised this already logged the underlying cause (with its
        # step/attempt context); ExecutionFailedError is control flow, not a new
        # error, so re-logging it here would just duplicate the row.
        Rails.logger.error { "ChronoForge:#{self.class}(#{key}) step execution failed" }
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
        error_log = self.class::ExecutionTracker.track_error(workflow, e, attempt: attempt)

        # Retry if applicable. `attempt` is a 0-based index, so the count of
        # attempts made so far (including this one) is attempt + 1.
        attempts_made = attempt + 1
        if policy.retryable?(e, attempts_made)
          self.class
            .set(wait: policy.backoff_for(attempts_made))
            .perform_later(workflow.key, attempt: attempts_made)
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

    # Retry policy for workflow-level (uncaught) errors: the class default if one
    # was declared, else the workflow built-in (10 attempts, up to ~8.5 min).
    # Each retry replays the whole workflow from the top.
    def workflow_retry_policy
      self.class.default_retry_policy || RetryPolicy.workflow_default
    end

    # Retry policy for a durable step: an explicit per-call override, else the
    # class default, else the step built-in (short, snappy fast-fail).
    def step_retry_policy(override)
      coerce_policy(override) || self.class.default_retry_policy || RetryPolicy.step_default
    end

    # Retry policy for a wait_until condition error. Deliberately does NOT inherit
    # the class default, so a class-wide "retry everything" can't silently turn
    # condition-evaluation bugs into retried errors. Built-in retries nothing.
    def wait_retry_policy(override)
      coerce_policy(override) || RetryPolicy.wait_default
    end

    # Normalize a retry-policy value: an Array becomes a composite; a RetryPolicy
    # or CompositeRetryPolicy passes through; nil stays nil.
    def coerce_policy(value)
      value.is_a?(Array) ? RetryPolicy.compose(*value) : value
    end

    # JSON metadata key holding the per-error attempt counts of a composite
    # policy, keyed by the matched policy's declared errors (RetryPolicy#budget_key).
    RETRY_COUNTS_KEY = "retry_counts"

    # Increment the matched policy's slot in the log's retry-count map and return
    # the new count. Reassigns `metadata` so the JSON column is marked dirty.
    def bump_retry_count!(log, policy_key)
      meta = log.metadata || {}
      counts = meta[RETRY_COUNTS_KEY] || {}
      counts[policy_key] = counts[policy_key].to_i + 1
      meta[RETRY_COUNTS_KEY] = counts
      log.update!(metadata: meta)
      counts[policy_key]
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
