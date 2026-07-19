# frozen_string_literal: true

require "rails/generators/active_record/migration"
require_relative "../migration_actions"

module ChronoForge
  # Creates the ChronoForge initializer and installs all migrations into a new
  # application. Idempotent: migrations that already exist are skipped, so
  # re-running is safe. Multi-database aware: with --database (or an already
  # configured config.database), migrations land in db/NAME_migrate.
  class InstallGenerator < Rails::Generators::Base
    include ::ActiveRecord::Generators::Migration
    include ChronoForge::Generators::MigrationActions

    source_root File.expand_path("../templates", __dir__)

    desc "Creates the ChronoForge initializer and installs its migrations. Pass " \
         "--database=NAME to run ChronoForge in its own database (multi-db)."

    def copy_initializer
      template "initializer.rb", "config/initializers/chrono_forge.rb"
    end

    # With --database, record config.database in the initializer so later
    # generator runs (e.g. chrono_forge:upgrade after a gem update) still
    # target the right directory without the flag. --database=primary means
    # "stay on the default connection", so nothing is recorded.
    def set_database_config
      return unless (db = chrono_forge_database)

      gsub_file "config/initializers/chrono_forge.rb", /^\s*#?\s*config\.database\s*=.*$/,
        %(  config.database = :#{db})
    end

    def copy_migrations
      copy_chrono_forge_migrations
    rescue => err
      say "#{err.class}: #{err}\n#{err.backtrace.join("\n")}", :red
      exit 1
    end

    def print_next_steps
      if (db = chrono_forge_database)
        say <<~MSG

          Add the '#{db}' database to config/database.yml (per environment), e.g.:

              #{db}:
                <<: *default
                database: myapp_#{db}
                migrations_paths: db/#{db}_migrate

          then run:  bin/rails db:migrate:#{db}
        MSG
      else
        say "\nNext: run bin/rails db:migrate"
      end
    end
  end
end
