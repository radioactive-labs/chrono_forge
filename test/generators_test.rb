require "test_helper"
require "rails/generators"
require "tmpdir"
require File.expand_path("../lib/generators/chrono_forge/install/install_generator.rb", __dir__)
require File.expand_path("../lib/generators/chrono_forge/upgrade/upgrade_generator.rb", __dir__)

class GeneratorsTest < ActiveJob::TestCase
  def migrations_in(dir)
    Dir.glob(File.join(dir, "db", "migrate", "*.rb")).map { |f| File.basename(f).sub(/\A\d+_/, "") }.sort
  end

  def run_generator(klass, dir, args = [])
    silence_stream($stdout) { klass.start(args, destination_root: dir) }
  end

  # Minitest doesn't ship silence_stream everywhere; provide a tiny shim.
  def silence_stream(stream)
    old = stream.dup
    stream.reopen(File::NULL)
    stream.sync = true
    yield
  ensure
    stream.reopen(old)
    old.close
  end

  def test_install_copies_all_migrations
    Dir.mktmpdir do |dir|
      run_generator(ChronoForge::InstallGenerator, dir)

      assert_equal(
        [
          "add_chrono_forge_error_log_step_context.rb",
          "add_chrono_forge_parent_execution_log.rb",
          "add_chrono_forge_workflow_state_index.rb",
          "install_chrono_forge.rb"
        ],
        migrations_in(dir),
        "install should copy every migration"
      )
    end
  end

  def test_a_migration_whose_name_merely_ends_in_a_gem_migration_name_does_not_suppress_the_copy
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
      File.write(File.join(dir, "db", "migrate", "20200101000000_my_install_chrono_forge.rb"), "# host decoy")

      run_generator(ChronoForge::InstallGenerator, dir)

      assert_includes migrations_in(dir), "install_chrono_forge.rb",
        "a host migration ending in a gem migration's name must not count as installed"
    end
  end

  def test_install_is_idempotent
    Dir.mktmpdir do |dir|
      run_generator(ChronoForge::InstallGenerator, dir)
      run_generator(ChronoForge::InstallGenerator, dir)

      # Re-running must not duplicate migrations.
      assert_equal 4, Dir.glob(File.join(dir, "db", "migrate", "*.rb")).size,
        "re-running install must not create duplicate migrations"
    end
  end

  def test_upgrade_copies_only_missing_migrations
    Dir.mktmpdir do |dir|
      # Simulate an app installed before the index migration existed: only the
      # original install migration is present.
      FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
      File.write(File.join(dir, "db", "migrate", "20240101000000_install_chrono_forge.rb"), "# existing\n")

      run_generator(ChronoForge::UpgradeGenerator, dir)

      names = migrations_in(dir)
      assert_includes names, "add_chrono_forge_workflow_state_index.rb",
        "upgrade should add the missing index migration"
      assert_equal 1, names.count("install_chrono_forge.rb"),
        "upgrade must not re-copy the existing install migration"
    end
  end

  def test_install_with_database_targets_db_name_migrate_and_records_it
    Dir.mktmpdir do |dir|
      run_generator(ChronoForge::InstallGenerator, dir, ["--database=chrono"])

      assert_equal 4, Dir.glob(File.join(dir, "db", "chrono_migrate", "*.rb")).size,
        "all migrations should land in db/chrono_migrate"
      assert_empty Dir.glob(File.join(dir, "db", "migrate", "*.rb")),
        "nothing should land in db/migrate when --database is given"

      initializer = File.read(File.join(dir, "config", "initializers", "chrono_forge.rb"))
      assert_match(/^  config\.database = :chrono$/, initializer,
        "install must record --database in the initializer for later upgrade runs")
    end
  end

  def test_install_generates_commented_initializer_by_default
    Dir.mktmpdir do |dir|
      run_generator(ChronoForge::InstallGenerator, dir)

      initializer = File.read(File.join(dir, "config", "initializers", "chrono_forge.rb"))
      assert_match(/# config\.database = :chrono_forge/, initializer)
      refute_match(/^  config\.database =/, initializer,
        "no active config.database line without --database")
    end
  end

  def test_install_with_primary_database_behaves_like_no_flag
    Dir.mktmpdir do |dir|
      run_generator(ChronoForge::InstallGenerator, dir, ["--database=primary"])

      assert_equal 4, Dir.glob(File.join(dir, "db", "migrate", "*.rb")).size,
        "--database=primary must install into db/migrate like the default"

      initializer = File.read(File.join(dir, "config", "initializers", "chrono_forge.rb"))
      refute_match(/^  config\.database =/, initializer,
        "--database=primary must not activate config.database (it would trigger connects_to at boot)")
    end
  end

  def test_install_with_database_is_idempotent
    Dir.mktmpdir do |dir|
      run_generator(ChronoForge::InstallGenerator, dir, ["--database=chrono"])
      run_generator(ChronoForge::InstallGenerator, dir, ["--database=chrono"])

      assert_equal 4, Dir.glob(File.join(dir, "db", "chrono_migrate", "*.rb")).size,
        "re-running install --database must not duplicate migrations"
    end
  end

  def test_upgrade_falls_back_to_config_database
    Dir.mktmpdir do |dir|
      ChronoForge.configure { |c| c.database = :chrono }
      FileUtils.mkdir_p(File.join(dir, "db", "chrono_migrate"))
      File.write(File.join(dir, "db", "chrono_migrate", "20240101000000_install_chrono_forge.rb"), "# existing\n")

      run_generator(ChronoForge::UpgradeGenerator, dir)

      names = Dir.glob(File.join(dir, "db", "chrono_migrate", "*.rb"))
        .map { |f| File.basename(f).sub(/\A\d+_/, "") }
      assert_includes names, "add_chrono_forge_workflow_state_index.rb",
        "upgrade should target db/chrono_migrate from config.database"
      assert_equal 1, names.count("install_chrono_forge.rb"),
        "upgrade must not re-copy the existing install migration"
    ensure
      ChronoForge.reset_configuration!
    end
  end
end
