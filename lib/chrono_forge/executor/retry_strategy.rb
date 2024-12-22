module ChronoForge
  module Executor
    class RetryStrategy
      BACKOFF_STRATEGY = [
        1.second,   # Initial retry
        5.seconds,  # Second retry
        30.seconds, # Third retry
        2.minutes,  # Fourth retry
        10.minutes  # Final retry
      ]

      def self.schedule_retry(workflow, attempt: 0)
        wait_duration = BACKOFF_STRATEGY[attempt] || BACKOFF_STRATEGY.last

        # Schedule with exponential backoff
        workflow.job_klass
          .set(wait: wait_duration)
          .perform_later(
            workflow.key,
            attempt: attempt + 1
          )
      end

      def self.max_attempts
        BACKOFF_STRATEGY.length
      end
    end
  end
end
