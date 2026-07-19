require "test_helper"

class ApplicationRecordTest < ActiveJob::TestCase
  def teardown
    ChronoForge.reset_configuration!
  end

  def test_models_inherit_from_chrono_forge_application_record
    [ChronoForge::Workflow, ChronoForge::ExecutionLog, ChronoForge::ErrorLog].each do |model|
      assert_equal ChronoForge::ApplicationRecord, model.superclass,
        "#{model} should inherit ChronoForge::ApplicationRecord"
    end
  end

  def test_application_record_is_abstract
    assert ChronoForge::ApplicationRecord.abstract_class?
  end

  def test_no_connects_to_settings_by_default
    assert_nil ChronoForge::ApplicationRecord.connects_to_settings
  end

  def test_database_config_derives_writing_and_reading_roles
    ChronoForge.configure { |c| c.database = :chrono_forge }
    assert_equal({database: {writing: :chrono_forge, reading: :chrono_forge}},
      ChronoForge::ApplicationRecord.connects_to_settings)
  end

  def test_connects_to_config_wins_over_database
    ChronoForge.configure do |c|
      c.database = :ignored
      c.connects_to = {database: {writing: :w, reading: :r}}
    end
    assert_equal({database: {writing: :w, reading: :r}},
      ChronoForge::ApplicationRecord.connects_to_settings)
  end

  def test_connects_to_routes_to_the_configured_database
    config = ChronoForge::Configuration.new
    config.database = :chrono

    klass = Class.new(ActiveRecord::Base) { self.abstract_class = true }
    Object.const_set(:ChronoSmokeRecord, klass)
    klass.connects_to(**ChronoForge::ApplicationRecord.connects_to_settings(config))

    assert_equal "chrono", klass.connection_db_config.name,
      "connects_to should route the class to the secondary database"
    assert klass.connection.execute("SELECT 1"),
      "the secondary database connection should be usable"
  ensure
    Object.send(:remove_const, :ChronoSmokeRecord) if defined?(::ChronoSmokeRecord)
  end
end
