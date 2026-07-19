# frozen_string_literal: true

# Proves config.connects_to wins over config.database in the class body of
# ChronoForge::ApplicationRecord, through the real wiring: database points at a
# config that does not exist, so if precedence ever flipped, connecting below
# would raise instead of reaching the `chrono` database. Runs in its own
# process (see test:multi_db in the Rakefile) because the class body reads the
# config exactly once, at first load.
require "test_helper"

ChronoForge.configure do |c|
  c.database = :nonexistent_database_proving_connects_to_wins
  c.connects_to = {database: {writing: :chrono, reading: :chrono}}
end

class ConnectsToPrecedenceTest < ActiveJob::TestCase
  def test_connects_to_hash_wins_over_database_for_the_connection
    assert_equal "chrono", ChronoForge::Workflow.connection_db_config.name
    assert_equal "chrono", ChronoForge::ExecutionLog.connection_db_config.name
    assert_equal "chrono", ChronoForge::ErrorLog.connection_db_config.name

    assert ChronoForge::ApplicationRecord.connection.select_value("SELECT 1"),
      "the connects_to-routed connection should be usable"
  end
end
