# frozen_string_literal: true

# == Schema Information
#
# Table name: chrono_forge_workflows
#
#  id           :integer          not null, primary key
#  completed_at :datetime
#  context      :json             not null
#  job_klass    :string           not null
#  key          :string           not null
#  kwargs       :json             not null
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
  class Workflow < ActiveRecord::Base
    self.table_name = "chrono_forge_workflows"

    has_many :execution_logs
    has_many :error_logs

    enum :state, %i[
      idle
      running
      completed
      failed
      stalled
    ]

    # Cleanup method
    def self.cleanup_old_logs(retention_period: 30.days)
      where("created_at < ?", retention_period.ago).delete_all
    end

    # Serialization for metadata
    serialize :metadata, coder: JSON

    def executable?
      idle? || running?
    end
  end
end
