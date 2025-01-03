module ChronoForge
  module Executor
    class LongRunningConcurrentExecutionError < Error; end

    class ConcurrentExecutionError < Error; end

    class LockStrategy
      def self.acquire_lock(job_id, workflow, max_duration:)
        ActiveRecord::Base.transaction do
          # Find the workflow with a lock, considering stale locks
          workflow = workflow.lock!

          # Check for active execution
          if workflow.locked_at && workflow.locked_at > max_duration.ago
            raise ConcurrentExecutionError, "Job currently in progress"
          end

          # Atomic update of lock status
          workflow.update_columns(
            locked_by: job_id,
            locked_at: Time.current,
            state: :running
          )

          workflow
        end
      end

      def self.release_lock(job_id, workflow)
        workflow = workflow.reload
        if workflow.locked_by != job_id
          raise LongRunningConcurrentExecutionError,
            "#{self.class}(#{job_id}) executed longer than specified max_duration, " \
            "allowing another instance(#{workflow.locked_by}) to acquire the lock."
        end

        columns = {locked_at: nil, locked_by: nil}
        columns[:state] = :idle if workflow.running?

        workflow.update_columns(columns)
      end
    end
  end
end
