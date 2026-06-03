# frozen_string_literal: true

require "rails/generators/active_record/migration"
require_relative "../migration_actions"

module ChronoForge
  # Brings an existing ChronoForge installation up to the current schema by
  # copying any migrations the application does not already have. Applications
  # created with `chrono_forge:install` on the current version already have
  # everything; older installs pick up the additive migrations (currently the
  # chrono_forge_workflows [state, completed_at] index).
  #
  #   rails generate chrono_forge:upgrade
  #   rails db:migrate
  class UpgradeGenerator < Rails::Generators::Base
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
