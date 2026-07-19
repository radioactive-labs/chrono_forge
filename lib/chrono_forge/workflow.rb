# frozen_string_literal: true

# == Schema Information
#
# Table name: chrono_forge_workflows
#
#  id           :integer          not null, primary key
#  completed_at :datetime
#  context      :json             not null
#  job_class    :string           not null
#  key          :string           not null
#  kwargs       :json             not null
#  options      :json             not null
#  locked_at    :datetime
#  parent_execution_log_id :integer
#  started_at   :datetime
#  state        :integer          default("idle"), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_chrono_forge_workflows_on_key                         (key)
#  index_chrono_forge_workflows_on_job_class_and_key           (job_class,key) UNIQUE
#  index_chrono_forge_workflows_on_parent_execution_log_and_st (parent_execution_log_id,state)
#  index_chrono_forge_workflows_on_state_and_completed_at      (state,completed_at)
#
module ChronoForge
  class Workflow < ApplicationRecord
    self.table_name = "chrono_forge_workflows"

    has_many :execution_logs, dependent: :destroy
    has_many :error_logs, dependent: :destroy

    belongs_to :parent_execution_log,
      class_name: "ChronoForge::ExecutionLog",
      inverse_of: :spawned_workflows,
      optional: true

    enum :state, %i[
      idle
      running
      completed
      failed
      stalled
    ]

    # Reconcile workflows stranded in :running by a hard-killed worker. When a
    # worker is SIGKILLed (deploy/rollout, OOM, node eviction, SolidQueue heartbeat
    # prune) mid-pass, the executor's `ensure` block never runs, so the lock is
    # never released (the row stays :running with a stale locked_at) and the resume
    # continuation is never published — nothing is left to wake the workflow. No
    # other mechanism recovers this: workflow-level retry rides on the same process
    # that must reach its `ensure`; retry_now/retry_later require stalled?/failed?;
    # and BranchMergeJob rekick only re-drives never-started idle children.
    #
    # This sweeps every workflow in :running whose lock is older than `stale_after`
    # (top-level AND branch children) and re-enqueues it. Re-enqueue is safe:
    # acquire_lock steals the stale lock and completed durable steps replay as
    # no-ops. Overlapping sweeps (or a re-enqueue landing while the old stale lock
    # still shows) at worst enqueue a duplicate, which loses the acquire_lock race
    # and no-ops via ConcurrentExecutionError.
    #
    # Intended to be run periodically by the host app (e.g. a SolidQueue recurring
    # task or cron). Returns the number of workflows re-enqueued.
    #
    # NOTE: replaying an interrupted pass re-runs any durably_execute step whose
    # side effect committed but whose log never reached :completed. Steps with
    # external side effects must be idempotent (natural/unique key +
    # create_or_find_by/rescue).
    def self.reap_stalled(stale_after: ChronoForge.config.reap_stale_after)
      reaped = 0
      where(state: states[:running])
        .where("locked_at < ?", stale_after.ago)
        .find_each do |workflow|
          # Guarded per row: one bad workflow (e.g. a since-deleted job class that
          # no longer constantizes, or cross-version kwarg drift tripping the
          # enqueue guard) must never abort the sweep and strand every healthy
          # sibling. Mirrors BranchMergeJob#rekick_dropped_jobs.
          workflow.job_klass.perform_later(workflow.key, **workflow.kwargs.symbolize_keys)
          reaped += 1
        rescue => e
          Rails.logger.error do
            "ChronoForge reap failed for workflow(#{workflow.key}): #{e.class}: #{e.message}"
          end
        end
      Rails.logger.info { "ChronoForge reaped #{reaped} stalled workflow(s)" } if reaped.positive?
      reaped
    end

    def executable?
      idle? || running?
    end

    # Only stalled or failed workflows can be re-executed.
    def retryable?
      stalled? || failed?
    end

    def ensure_retryable!
      return if retryable?

      raise Executor::WorkflowNotRetryableError,
        "Cannot retry workflow(#{key}) in #{state} state. Only stalled or failed workflows can be retried."
    end

    # Re-execute this workflow from its record, without constantizing the job
    # class or re-passing the key. Retryability is validated up front so a
    # non-retryable workflow raises immediately rather than enqueuing a job that
    # would fail in the worker.
    def retry_now(**)
      ensure_retryable!
      job_klass.retry_now(key, **)
    end

    def retry_later(**)
      ensure_retryable!
      job_klass.retry_later(key, **)
    end

    def job_klass
      job_class.constantize
    end
  end
end
