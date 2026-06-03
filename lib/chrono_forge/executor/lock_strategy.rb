module ChronoForge
  module Executor
    class LongRunningConcurrentExecutionError < Error; end

    class ConcurrentExecutionError < Error; end

    class LockStrategy
      class << self
        def acquire_lock(job_id, workflow, max_duration:)
          ActiveRecord::Base.transaction do
            # Find the workflow with a lock, considering stale locks
            workflow = workflow.lock!

            ensure_executable!(workflow)

            # Check for active execution
            if workflow.locked_at && workflow.locked_at > max_duration.ago
              raise ConcurrentExecutionError,
                "ChronoForge:#{self.class}(#{key}) job(#{job_id}) failed to acquire lock. " \
                "Currently being executed by job(#{workflow.locked_by})"
            end

            # Atomic update of lock status
            workflow.update_columns(
              locked_by: job_id,
              locked_at: Time.current,
              state: :running
            )

            Rails.logger.debug { "ChronoForge:#{self.class}(#{workflow.key}) job(#{job_id}) acquired lock." }

            workflow
          end
        end

        def release_lock(job_id, workflow, force: false)
          # Read only the lock owner from the DB rather than reloading the whole
          # row (which would drag the heavy context/kwargs/options JSON into memory
          # on every resume) just to verify ownership. The in-memory state is
          # already accurate here: acquire_lock set it to :running, and a
          # completed/failed workflow had its state updated on this same instance.
          current_locked_by = workflow.class.where(id: workflow.id).pick(:locked_by)

          if !force && current_locked_by != job_id
            raise LongRunningConcurrentExecutionError,
              "ChronoForge:#{self.class}(#{workflow.key}) job(#{job_id}) executed longer than specified max_duration, " \
              "allowed job(#{current_locked_by}) to acquire the lock."
          end

          columns = {locked_at: nil, locked_by: nil}
          columns[:state] = :idle if force || workflow.running?

          workflow.update_columns(columns)
        end

        private

        def ensure_executable!(workflow)
          # Raise error if workflow cannot be executed
          unless workflow.executable?
            raise NotExecutableError, "ChronoForge:#{workflow.class}(#{workflow.key}) is not in an executable state"
          end
        end
      end
    end
  end
end
