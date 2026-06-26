require "test_helper"
require File.expand_path(
  "../lib/generators/chrono_forge/templates/add_chrono_forge_workflow_state_index.rb",
  __dir__
)
require File.expand_path(
  "../lib/generators/chrono_forge/templates/add_chrono_forge_parent_execution_log.rb",
  __dir__
)

# Exercises the upgrade migration shipped for existing installations (which
# already ran the original install migration and therefore need a separate,
# idempotent migration to pick up the new index).
class UpgradeMigrationTest < ActiveJob::TestCase
  def connection
    ChronoForge::Workflow.connection
  end

  def index_present?
    connection.index_exists?(:chrono_forge_workflows, %i[state completed_at])
  end

  def silence_migration
    ActiveRecord::Migration.suppress_messages { yield }
  end

  def test_migration_adds_index_and_is_idempotent
    # Simulate an existing install that does not yet have the index.
    connection.remove_index(:chrono_forge_workflows, %i[state completed_at]) if index_present?
    refute index_present?, "precondition: index removed"

    silence_migration { AddChronoForgeWorkflowStateIndex.new.migrate(:up) }
    assert index_present?, "migration should add the [state, completed_at] index"

    # Running it again must not raise (if_not_exists guard) — important because
    # operators may re-run migrations.
    assert_nothing_raised do
      silence_migration { AddChronoForgeWorkflowStateIndex.new.migrate(:up) }
    end
    assert index_present?
  ensure
    # Restore schema for the rest of the suite regardless of outcome.
    connection.add_index(:chrono_forge_workflows, %i[state completed_at]) unless index_present?
  end

  def parent_log_column_present?
    connection.column_exists?(:chrono_forge_workflows, :parent_execution_log_id)
  end

  def parent_log_index_present?
    connection.index_exists?(:chrono_forge_workflows, %i[parent_execution_log_id state])
  end

  def test_migration_adds_parent_execution_log_and_is_idempotent
    # Simulate an existing install that predates the parent_execution_log_id
    # column/index.
    connection.remove_index(:chrono_forge_workflows, %i[parent_execution_log_id state]) if parent_log_index_present?
    connection.remove_column(:chrono_forge_workflows, :parent_execution_log_id) if parent_log_column_present?
    refute parent_log_column_present?, "precondition: column removed"
    refute parent_log_index_present?, "precondition: index removed"

    silence_migration { AddChronoForgeParentExecutionLog.new.migrate(:up) }
    assert parent_log_column_present?, "migration should add the parent_execution_log_id column"
    assert parent_log_index_present?, "migration should add the [parent_execution_log_id, state] index"

    # Running it again must not raise (if_not_exists guards) — operators may
    # re-run migrations.
    assert_nothing_raised do
      silence_migration { AddChronoForgeParentExecutionLog.new.migrate(:up) }
    end
    assert parent_log_column_present?
    assert parent_log_index_present?
  ensure
    # Restore schema for the rest of the suite regardless of outcome.
    connection.add_column(:chrono_forge_workflows, :parent_execution_log_id, :bigint, null: true) unless parent_log_column_present?
    connection.add_index(:chrono_forge_workflows, %i[parent_execution_log_id state]) unless parent_log_index_present?
  end
end
