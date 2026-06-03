# frozen_string_literal: true

require "rails/generators/active_record/migration"
require_relative "../migration_actions"

module ChronoForge
  # Installs all ChronoForge migrations into a new application. Idempotent:
  # migrations that already exist are skipped, so re-running is safe.
  class InstallGenerator < Rails::Generators::Base
    include ::ActiveRecord::Generators::Migration
    include ChronoForge::Generators::MigrationActions

    source_root File.expand_path("../templates", __dir__)

    def start
      copy_chrono_forge_migrations
    rescue => err
      say "#{err.class}: #{err}\n#{err.backtrace.join("\n")}", :red
      exit 1
    end
  end
end
