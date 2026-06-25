module ChronoForge
  module Executor
    # An ordered list of RetryPolicy objects, each scoped to an error type via
    # its `retry_on`. On failure the first policy whose `retry_on` matches the
    # raised error (by `is_a?`) is applied, giving each error type its own
    # independent attempt budget and backoff curve. Put specific policies first
    # and a catch-all (`retry_on: nil`) last; an unmatched error is not retried.
    #
    # Pure: it never reads storage. The per-error count is supplied by the
    # caller through the block passed to #retry_backoff, keyed by the matched
    # policy's index.
    class CompositeRetryPolicy
      attr_reader :policies

      def initialize(policies)
        @policies = Array(policies)
        if @policies.empty?
          raise ArgumentError, "composite retry policy needs at least one policy"
        end
      end

      # First sub-policy whose retry_on matches the error, or nil.
      def policy_for(error)
        @policies.find { |p| p.matches?(error) }
      end

      # Routes on the live error and delegates the decision to the matched
      # sub-policy. When a block is given it is called with the matched policy's
      # index and must return that policy's running attempt count (1-based,
      # including the current failure); otherwise `attempts` is used.
      def retry_backoff(error, attempts:)
        index = @policies.index { |p| p.matches?(error) }
        return nil if index.nil?

        sub = @policies[index]
        count = block_given? ? yield(index) : attempts
        sub.retryable?(error, count) ? sub.backoff_for(count) : nil
      end

      # Coarsest attempt bound across sub-policies, for the workflow-level
      # safety-net guard. nil (unbounded) if any sub-policy is unbounded.
      def max_attempts
        caps = @policies.map(&:max_attempts)
        caps.include?(nil) ? nil : caps.max
      end
    end
  end
end
