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

          Rails.logger.debug { "ChronoForge:#{self.class} job(#{job_id}) acquired lock for workflow(#{workflow.key})" }

          workflow
        end
      end

      def self.release_lock(job_id, workflow, force: false)
        workflow = workflow.reload
        if !force && workflow.locked_by != job_id
          raise LongRunningConcurrentExecutionError,
            "ChronoForge:#{self.class} job(#{job_id}) executed longer than specified max_duration, " \
            "allowed another instance job(#{workflow.locked_by}) to acquire the lock."
        end

        columns = {locked_at: nil, locked_by: nil}
        columns[:state] = :idle if force || workflow.running?


        workflow.update_columns(columns)
      end
    end
  end
end
