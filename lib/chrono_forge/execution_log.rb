# frozen_string_literal: true

# == Schema Information
#
# Table name: chrono_forge_execution_logs
#
#  id               :integer          not null, primary key
#  attempts         :integer          default(0), not null
#  completed_at     :datetime
#  error_class      :string
#  error_message    :text
#  last_executed_at :datetime
#  metadata         :json
#  started_at       :datetime
#  state            :integer          default("pending"), not null
#  step_name        :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  workflow_id      :integer          not null
#
# Indexes
#
#  idx_on_workflow_id_step_name_11bea8586e               (workflow_id,step_name) UNIQUE
#  index_chrono_forge_execution_logs_on_workflow_id  (workflow_id)
#
# Foreign Keys
#
#  workflow_id  (workflow_id => chrono_forge_workflows.id)
#
module ChronoForge
  class ExecutionLog < ActiveRecord::Base
    self.table_name = "chrono_forge_execution_logs"

    belongs_to :workflow

    enum :state, %i[
      pending
      completed
      failed
    ]

    # Cleanup method
    def self.cleanup_old_logs(retention_period: 30.days)
      where("created_at < ?", retention_period.ago).delete_all
    end
  end
end
