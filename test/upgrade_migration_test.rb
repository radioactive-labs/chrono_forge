require "test_helper"
require File.expand_path(
  "../lib/generators/chrono_forge/templates/add_chrono_forge_workflow_state_index.rb",
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
end
