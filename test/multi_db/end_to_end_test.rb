# frozen_string_literal: true

# End-to-end multi-database check. Runs in its own process (see the dedicated
# test:multi_db task in the Rakefile): config.database is set here, before any
# ChronoForge model loads — exactly like a host app's initializer — so
# ChronoForge::ApplicationRecord picks it up at class load and every model
# routes to the secondary `chrono` database. In the main suite's process this
# would re-route every other test, which is why it can't live there.
require "test_helper"

ChronoForge.configure { |c| c.database = :chrono }

class MultiDbEndToEndJob < ActiveJob::Base
  prepend ChronoForge::Executor

  def perform
    durably_execute :record
    context[:done] = true
  end

  def record
    context[:recorded_at] = Time.now.iso8601
  end
end

class MultiDbEndToEndTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def test_workflow_runs_entirely_in_the_secondary_database
    # ApplicationRecord read the config at class load, like in a host app.
    assert_equal "chrono", ChronoForge::Workflow.connection_db_config.name
    assert_equal "chrono", ChronoForge::ExecutionLog.connection_db_config.name
    assert_equal "chrono", ChronoForge::ErrorLog.connection_db_config.name

    # Install the schema on the secondary database with the real shipped
    # migrations (Combustion only migrated the primary at boot).
    conn = ChronoForge::ApplicationRecord.connection
    ActiveRecord::Migration.suppress_messages do
      [InstallChronoForge, AddChronoForgeWorkflowStateIndex,
        AddChronoForgeErrorLogStepContext, AddChronoForgeParentExecutionLog].each do |migration|
        migration.new.exec_migration(conn, :up)
      end
    end

    MultiDbEndToEndJob.perform_later("multi-db-e2e")
    perform_all_jobs

    workflow = ChronoForge::Workflow.last
    assert workflow, "workflow row should exist in the chrono database"
    assert workflow.completed?, "workflow should complete normally on the secondary database"
    assert_equal "multi-db-e2e", workflow.key
    assert workflow.context["recorded_at"], "durably_execute step should have run"
    assert_equal 2, workflow.execution_logs.count

    # The primary database has the same tables (Combustion boot migrations)
    # but no rows: everything went to chrono.
    assert_equal 0,
      ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM chrono_forge_workflows").to_i,
      "primary database must not receive workflow rows"
    assert_equal 1, ChronoForge::Workflow.count
  end
end
