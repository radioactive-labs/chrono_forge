# frozen_string_literal: true

# == Schema Information
#
# Table name: chrono_forge_error_logs
#
#  id            :integer          not null, primary key
#  backtrace     :text
#  context       :json
#  error_class   :string
#  error_message :text
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  workflow_id   :integer          not null
#
# Indexes
#
#  index_chrono_forge_error_logs_on_workflow_id  (workflow_id)
#
# Foreign Keys
#
#  workflow_id  (workflow_id => chrono_forge_workflows.id)
#

module ChronoForge
  class ErrorLog < ApplicationRecord()
    self.table_name = "chrono_forge_error_logs"

    belongs_to :workflow
  end
end
