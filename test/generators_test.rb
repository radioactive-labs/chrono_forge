require "test_helper"
require "rails/generators"
require "tmpdir"
require File.expand_path("../lib/generators/chrono_forge/install/install_generator.rb", __dir__)
require File.expand_path("../lib/generators/chrono_forge/upgrade/upgrade_generator.rb", __dir__)

class GeneratorsTest < ActiveJob::TestCase
  def migrations_in(dir)
    Dir.glob(File.join(dir, "db", "migrate", "*.rb")).map { |f| File.basename(f).sub(/\A\d+_/, "") }.sort
  end

  def run_generator(klass, dir)
    silence_stream($stdout) { klass.start([], destination_root: dir) }
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
        ["add_chrono_forge_workflow_state_index.rb", "install_chrono_forge.rb"],
        migrations_in(dir),
        "install should copy every migration"
      )
    end
  end

  def test_install_is_idempotent
    Dir.mktmpdir do |dir|
      run_generator(ChronoForge::InstallGenerator, dir)
      run_generator(ChronoForge::InstallGenerator, dir)

      # Re-running must not duplicate migrations.
      assert_equal 2, Dir.glob(File.join(dir, "db", "migrate", "*.rb")).size,
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
end
