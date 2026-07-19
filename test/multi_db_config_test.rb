require "test_helper"

class MultiDbConfigTest < ActiveJob::TestCase
  def teardown
    ChronoForge.reset_configuration!
    Rails.application.config.generators.options[:active_record].delete(:primary_key_type)
  end

  def test_primary_key_type_defaults_to_bigint
    assert_equal :bigint, ChronoForge.primary_key_type
  end

  def test_explicit_primary_key_type_wins
    ChronoForge.configure { |c| c.primary_key_type = :uuid }
    assert_equal :uuid, ChronoForge.primary_key_type
  end

  def test_primary_key_type_falls_back_to_app_generators_setting
    Rails.application.config.generators.options[:active_record][:primary_key_type] = :uuid
    assert_equal :uuid, ChronoForge.primary_key_type
  end

  def test_explicit_config_beats_app_generators_setting
    Rails.application.config.generators.options[:active_record][:primary_key_type] = :uuid
    ChronoForge.configure { |c| c.primary_key_type = :bigint }
    assert_equal :bigint, ChronoForge.primary_key_type
  end

  def test_migrations_database_nil_by_default
    assert_nil ChronoForge.config.migrations_database
  end

  def test_migrations_database_prefers_explicit_database
    ChronoForge.configure do |c|
      c.database = :chrono
      c.connects_to = {database: {writing: :other, reading: :other}}
    end
    assert_equal :chrono, ChronoForge.config.migrations_database
  end

  def test_migrations_database_derives_from_connects_to_writing_role
    ChronoForge.configure { |c| c.connects_to = {database: {writing: :chrono, reading: :replica}} }
    assert_equal :chrono, ChronoForge.config.migrations_database
  end

  def test_install_migration_uses_configured_primary_key_type
    ChronoForge.configure { |c| c.primary_key_type = :uuid }
    assert_equal :uuid, InstallChronoForge.new.send(:primary_key_type),
      "install migration should resolve its PK type via ChronoForge.primary_key_type"
  end
end
