module ChronoForge
  module Executor
    # A single, unified description of retry behavior shared by every retry site
    # (workflow-level uncaught errors, durably_execute, durably_repeat, and
    # wait_until's condition errors).
    #
    # It answers the only two questions a retry site ever asks:
    #   - retryable?(error, attempts) — should this failure be retried?
    #   - backoff_for(attempts)       — how long until the next attempt?
    #
    # `attempts` is always the 1-based count of attempts made so far, *including*
    # the one that just failed (matching ExecutionLog#attempts). So on the first
    # failure `attempts == 1`.
    class RetryPolicy
      attr_reader :max_attempts, :base, :cap, :jitter, :retry_on

      # @param max_attempts [Integer, nil] cap on total attempts; nil = no count
      #   cap (bounded elsewhere, e.g. wait_until's timeout)
      # @param base [Numeric, ActiveSupport::Duration] delay of the first retry
      # @param cap [Numeric, ActiveSupport::Duration] ceiling for a single delay
      # @param jitter [Boolean] apply equal jitter to spread retries
      # @param retry_on [Array<Class>, nil] nil = retry any StandardError;
      #   an array = retry only those classes (and subclasses); [] = retry nothing
      def initialize(max_attempts: 3, base: 1, cap: 30, jitter: true, retry_on: nil)
        @max_attempts = max_attempts
        @base = base
        @cap = cap
        @jitter = jitter
        @retry_on = retry_on
      end

      def retryable?(error, attempts)
        within_attempt_cap?(attempts) && retryable_error?(error)
      end

      # Equal jitter: half the computed delay plus a random portion of the other
      # half. Computed once at re-enqueue time and never persisted, so the
      # randomness does not affect replay determinism.
      def backoff_for(attempts)
        exponent = [attempts - 1, 0].max
        delay = [cap.to_f, base.to_f * (2**exponent)].min
        delay = (delay / 2) + rand(0.0..(delay / 2)) if jitter
        delay.seconds
      end

      def self.step_default
        new(max_attempts: 3, base: 1, cap: 30, jitter: true, retry_on: nil)
      end

      # Workflow-level (uncaught) errors retry the whole workflow from the top
      # (replaying completed steps). They cover two populations the default can't
      # distinguish: transient infra blips — worth riding out — and deterministic
      # bugs, where every replay is waste. 10 attempts gives a tolerant window of
      # up to ~8.5 min (≈4 min typical, since equal jitter puts each wait in
      # [d/2, d]) — enough for a DB failover or deploy restart — without dragging
      # out the bug case; cap (600s / 10 min) bounds any single backoff and only
      # binds if a caller configures more attempts.
      def self.workflow_default
        new(max_attempts: 10, base: 1, cap: 600, jitter: true, retry_on: nil)
      end

      def self.wait_default
        new(max_attempts: nil, base: 1, cap: 30, jitter: true, retry_on: [])
      end

      private

      def within_attempt_cap?(attempts)
        max_attempts.nil? || attempts < max_attempts
      end

      def retryable_error?(error)
        if retry_on.nil?
          error.is_a?(StandardError)
        else
          retry_on.any? { |klass| error.is_a?(klass) }
        end
      end
    end
  end
end
