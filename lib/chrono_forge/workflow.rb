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

    enum :state, %i[
      idle
      running
      completed
      failed
      stalled
    ]

    # Serialization for metadata
    serialize :metadata, coder: JSON

    def executable?
      idle? || running?
    end

    def job_klass
      job_class.constantize
    end
  end
end
