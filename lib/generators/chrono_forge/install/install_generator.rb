# frozen_string_literal: true

require "rails/generators/active_record/migration"

module ChronoForge
  class InstallGenerator < Rails::Generators::Base
    include ::ActiveRecord::Generators::Migration

    source_root File.expand_path("templates", __dir__)

    def start
      install_migrations
    rescue => err
      say "#{err.class}: #{err}\n#{err.backtrace.join("\n")}", :red
      exit 1
    end

    private

    def install_migrations
      migration_template "install_chrono_forge.rb", "install_chrono_forge.rb"
    end
  end
end
