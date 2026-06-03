# frozen_string_literal: true

# Adds step context to error logs so each error can be attributed to the step
# and attempt it came from — making error logs orderable and correlatable when
# tailing a workflow, instead of an undifferentiated stream. Both columns are
# nullable (a workflow-level error has no step), so this is a safe additive
# change with no table rewrite.
class AddChronoForgeErrorLogStepContext < ActiveRecord::Migration[7.1]
  def change
    add_column :chrono_forge_error_logs, :step_name, :string, if_not_exists: true
    add_column :chrono_forge_error_logs, :attempt, :integer, if_not_exists: true
  end
end
