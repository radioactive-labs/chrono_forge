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
#  started_at   :datetime
#  state        :integer          default("idle"), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_chrono_forge_workflows_on_key  (key) UNIQUE
#
module ChronoForge
  class Workflow < ApplicationRecord()
    self.table_name = "chrono_forge_workflows"

    has_many :execution_logs, dependent: :destroy
    has_many :error_logs, dependent: :destroy

    belongs_to :parent_execution_log,
      class_name: "ChronoForge::ExecutionLog", optional: true

    enum :state, %i[
      idle
      running
      completed
      failed
      stalled
    ]

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
