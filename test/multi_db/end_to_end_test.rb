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

    install_chrono_schema

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

  # The lock is a read-then-update, and only a transaction on the connection
  # holding the row makes that atomic. Opening one on ActiveRecord::Base instead
  # leaves it on the host's primary while the lock! and the UPDATE run
  # unprotected on chrono, so two workers can each see the workflow as unlocked
  # and both claim it. Single-database runs cannot catch that: there, the two
  # constants share a connection and the wrong one still works.
  def test_the_lock_is_taken_inside_a_transaction_on_the_chrono_connection
    install_chrono_schema

    observed = []
    ChronoForge::Workflow.singleton_class.send(:define_method, :__observe) { observed }
    ChronoForge::Workflow.class_eval do
      alias_method :__orig_lock!, :lock!
      def lock!(*args)
        self.class.__observe << self.class.connection.transaction_open?
        __orig_lock!(*args)
      end
    end

    begin
      MultiDbEndToEndJob.perform_later("multi-db-lock-connection")
      perform_all_jobs

      refute_empty observed, "lock! should have been reached"
      assert observed.all?, "the lock must be held in a transaction on ChronoForge's own connection"
    ensure
      ChronoForge::Workflow.class_eval do
        remove_method :lock!
        alias_method :lock!, :__orig_lock!
        remove_method :__orig_lock!
      end
    end
  end

  private

  # Combustion only migrated the primary at boot, so the secondary needs the
  # real shipped migrations. Guarded because both tests need it and minitest
  # does not promise an order.
  def install_chrono_schema
    conn = ChronoForge::ApplicationRecord.connection
    return if conn.table_exists?("chrono_forge_workflows")

    ActiveRecord::Migration.suppress_messages do
      [InstallChronoForge, AddChronoForgeWorkflowStateIndex,
        AddChronoForgeErrorLogStepContext, AddChronoForgeParentExecutionLog].each do |migration|
        migration.new.exec_migration(conn, :up)
      end
    end
  end
end
