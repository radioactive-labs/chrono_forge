module ChronoForge
  module Executor
    class Error < StandardError; end

    class ExecutionFailedError < Error; end

    class ExecutionFlowControl < Error; end

    class HaltExecutionFlow < ExecutionFlowControl; end

    class NotExecutableError < Error; end

    class WorkflowNotRetryableError < NotExecutableError; end

    class InvalidStepName < NotExecutableError; end

    # spawn/spawn_each called outside a branch block. NotExecutableError so it
    # propagates (fail-fast on a programming error) rather than being retried.
    class NotInBranchError < NotExecutableError; end

    # A branch was opened but neither merged via merge_branches nor declared
    # automerge: true. Raised at the completion gate. Fail-fast (not retried).
    class UnmergedBranchError < NotExecutableError; end

    # merge_branches given a name that was never opened as a branch this pass.
    # NotExecutableError so it propagates (fail-fast) instead of being retried.
    class UnknownBranchError < NotExecutableError; end

    # "$" separates the segments of a step name (e.g. "durably_repeat$name$ts").
    # User-supplied names/methods must not contain it.
    STEP_NAME_DELIMITER = "$"

    # Keyword args ChronoForge threads through job args internally. Users must
    # not pass these to perform_now/perform_later; the framework injects them
    # via `.set(...)` continuations, whose ConfiguredJob proxy bypasses the
    # class-level guard in `prepended` below.
    RESERVED_KWARGS = %i[attempt retry_counts retry_workflow].freeze

    include Methods

    # Add class methods
    def self.prepended(base)
      # Class-wide default retry policy, inherited by subclasses. Set via the
      # `retry_policy` DSL below; nil means "use the per-site built-in default".
      base.class_attribute :default_retry_policy, instance_accessor: false, default: nil

      class << base
        # Public enqueue contract: exactly one positional (`key`) plus keywords.
        # Reserved internal kwargs (RESERVED_KWARGS) are rejected here; the
        # framework injects them only via `.set(...)` continuations, whose
        # ActiveJob ConfiguredJob proxy bypasses these class-level overrides.
        def perform_now(key, *extra, **kwargs)
          __validate_enqueue!(key, extra, kwargs)
          super(key, **kwargs)
        end

        def perform_later(key, *extra, **kwargs)
          __validate_enqueue!(key, extra, kwargs)
          super(key, **kwargs)
        end

        # Re-run a failed/stalled workflow. Routes through `.set(...)` so the
        # reserved `retry_workflow: true` flag reaches the instance perform
        # without tripping the public guard above.
        def retry_now(key, **kwargs)
          __validate_enqueue!(key, [], kwargs)
          set.perform_now(key, retry_workflow: true, **kwargs)
        end

        def retry_later(key, **kwargs)
          __validate_enqueue!(key, [], kwargs)
          set.perform_later(key, retry_workflow: true, **kwargs)
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

        private

        def __validate_enqueue!(key, extra, kwargs)
          unless key.is_a?(String)
            raise ArgumentError, "Workflow key must be a string as the first argument"
          end
          unless extra.empty?
            raise ArgumentError,
              "ChronoForge workflows accept only `key` positionally; pass " \
              "everything else as keywords (got #{extra.size} extra positional arg(s))"
          end
          reserved = kwargs.keys & RESERVED_KWARGS
          if reserved.any?
            raise ArgumentError,
              "#{reserved.join(", ")} #{reserved.one? ? "is a reserved" : "are reserved"} " \
              "ChronoForge #{reserved.one? ? "keyword" : "keywords"} and cannot be passed to perform_now/perform_later"
          end
        end
      end
    end

    def perform(key, attempt: 0, retry_counts: {}, retry_workflow: false, options: {}, **kwargs)
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
        # attempts made so far (including this one) is attempt + 1. For a
        # composite policy the per-error budget lives in `retry_counts` (keyed by
        # the matched policy's budget_key) and rides along the job args, mirroring
        # how `attempt` is threaded — there is no execution log at this level.
        attempts_made = attempt + 1
        backoff = policy.retry_backoff(e, attempts: attempts_made) do |policy_key|
          retry_counts[policy_key] = retry_counts[policy_key].to_i + 1
          retry_counts[policy_key]
        end
        if backoff
          enqueue_continuation(wait: backoff, attempt: attempts_made, retry_counts: retry_counts)
        else
          fail_workflow! error_log
        end
      ensure
        if lock_acquired # Only release lock if we acquired it
          # Release the lock and publish the continuation even if context.save!
          # raises — otherwise a transient save failure would leave the lock held
          # (until it goes stale) AND drop the continuation, stranding the workflow
          # with nothing scheduled to resume it. On a save failure the continuation
          # resumes from the last persisted context, which is exactly crash
          # semantics (durable steps replay).
          begin
            context.save!
          ensure
            self.class::LockStrategy.release_lock(job_id, workflow)
            # Publish the continuation only now — after the lock is released — so a
            # zero-delay, same-key continuation can't lose the acquire race against
            # this still-locked job. If release_lock raised (this job overran and
            # lost the lock), we never reach here and another job owns continuation.
            flush_continuation!
          end
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

      # Branch children are pre-inserted by their parent (dispatch_children's
      # insert_all), so the creation block above never runs for them and their
      # started_at stays nil. Stamp it the first time the child actually executes
      # so started_at reliably means "has been picked up and run" — the
      # BranchMergeJob rekick poller treats a nil started_at as a never-executed
      # (dropped) child, and must not mistake a child that ran and is now parked
      # on a wait (also :idle) for one that was never picked up.
      @workflow.update_column(:started_at, Time.current) if @workflow.started_at.nil?
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
    #
    # Completed steps are short-circuited up front from a single bulk read (see
    # #completed_step_cache) so that replaying N already-done steps costs one
    # query for the whole batch rather than one SELECT each — without that, a
    # workflow with hundreds of steps pays hundreds of SELECTs on every resume.
    # The cached value is a readonly, unsaved stand-in: completed steps are only
    # ever read (.completed? and metadata["result"]), never written, so it needs
    # no database row.
    def find_or_create_execution_log!(step_name, &)
      if completed_step_cache.key?(step_name)
        return ExecutionLog.new(
          workflow: @workflow, step_name: step_name, state: :completed,
          metadata: completed_step_cache[step_name]
        ).tap(&:readonly!)
      end

      ExecutionLog.find_by(workflow: @workflow, step_name: step_name) ||
        ExecutionLog.create_or_find_by!(workflow: @workflow, step_name: step_name, &)
    end

    # One bulk read of this workflow's completed steps, mapping step_name to its
    # metadata, memoized for the duration of a single replay pass.
    #
    # Only completed rows are loaded: they are the ones replayed steps short-
    # circuit on, and once completed a step never changes, so the snapshot stays
    # valid for the whole pass. Plucking (step_name, metadata) avoids
    # instantiating AR objects and keeps the read portable — Rails type-casts the
    # JSON metadata column to a Hash on SQLite, PostgreSQL and MySQL alike, with
    # no database-specific JSON extraction.
    #
    # durably_repeat repetition logs (durably_repeat$<name>$<timestamp>) are
    # deliberately excluded: they accumulate without bound yet are never replayed
    # (durably_repeat only ever looks up its coordination log plus the single
    # current repetition), so pulling them into memory would be all cost and no
    # benefit. Their coordination log (durably_repeat$<name>, only two segments)
    # is not matched by the pattern and is still cached.
    def completed_step_cache
      @completed_step_cache ||= ExecutionLog
        .where(workflow: @workflow, state: ExecutionLog.states[:completed])
        .where.not("step_name LIKE ?", "durably_repeat#{STEP_NAME_DELIMITER}%#{STEP_NAME_DELIMITER}%")
        .pluck(:step_name, :metadata)
        .to_h
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

    # Record the continuation this job intends to enqueue. It is NOT published
    # here: publishing while the lock is still held lets another worker claim it
    # and lose the lock-acquisition race. The executor flushes it in `ensure`,
    # after release_lock (see #flush_continuation!). At most one continuation is
    # recorded per job run (every primitive records one then halts, or falls
    # through the workflow-retry rescue).
    def enqueue_continuation(wait:, **kwargs)
      @continuation = {wait: wait, kwargs: kwargs}
    end

    # Publish the recorded continuation, if any. Called from `ensure` only after
    # the lock row has been updated to released, so even a zero-delay continuation
    # finds the lock free.
    def flush_continuation!
      return unless @continuation

      self.class
        .set(wait: @continuation[:wait])
        .perform_later(@workflow.key, **@continuation[:kwargs])
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
