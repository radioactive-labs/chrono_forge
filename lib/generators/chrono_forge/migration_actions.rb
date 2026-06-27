# frozen_string_literal: true

module ChronoForge
  module Generators
    # Shared migration-copy logic for the install and upgrade generators.
    #
    # Copying is idempotent: a migration whose name already exists in the host
    # application's db/migrate is skipped, so it is safe to re-run either
    # generator. `install` copies the full set (a fresh app has none yet);
    # `upgrade` copies only the migrations a previously-installed app is missing.
    # Both share this method — the difference is purely which migrations already
    # exist in the target app.
    #
    # MIGRATIONS is listed in application order; copying preserves that order
    # because each migration_template assigns the next sequential version number.
    module MigrationActions
      MIGRATIONS = %w[
        install_chrono_forge
        add_chrono_forge_workflow_state_index
        add_chrono_forge_error_log_step_context
        add_chrono_forge_parent_execution_log
      ].freeze

      def copy_chrono_forge_migrations
        MIGRATIONS.each do |name|
          if chrono_forge_migration_exists?(name)
            say_status :skip, "#{name} (migration already exists)", :yellow
          else
            migration_template "#{name}.rb", "db/migrate/#{name}.rb"
          end
        end
      end

      def chrono_forge_migration_exists?(name)
        migrate_dir = File.join(destination_root, "db", "migrate")
        Dir.glob(File.join(migrate_dir, "*_#{name}.rb")).any?
      end
    end
  end
end
