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

      # Both generators take --database so a multi-db install/upgrade can be
      # driven from the command line; without it they fall back to the
      # configured database (config.database / connects_to writing role).
      def self.included(base)
        base.class_option :database, type: :string, aliases: "-d", default: nil, banner: "NAME",
          desc: "Install migrations into db/NAME_migrate for this database " \
                "(defaults to config.database / connects_to; 'primary' means " \
                "the default connection and db/migrate)"
      end

      def copy_chrono_forge_migrations
        MIGRATIONS.each do |name|
          if chrono_forge_migration_exists?(name)
            say_status :skip, "#{name} (migration already exists)", :yellow
          else
            migration_template "#{name}.rb", "#{chrono_forge_migrations_dir}/#{name}.rb"
          end
        end
      end

      # db/migrate on the primary connection; db/<name>_migrate when
      # ChronoForge lives in its own database.
      def chrono_forge_migrations_dir
        db = chrono_forge_database
        db.nil? ? "db/migrate" : "db/#{db}_migrate"
      end

      # The database ChronoForge should be installed into, nil when it stays on
      # the primary connection. "primary" is normalized to nil here so every
      # consumer (migration dir, initializer recording, next-steps message)
      # agrees that it means the default.
      def chrono_forge_database
        db = options[:database].presence || ChronoForge.config.migrations_database
        (db.to_s == "primary") ? nil : db
      end

      def chrono_forge_migration_exists?(name)
        Dir.glob(File.join(destination_root, chrono_forge_migrations_dir, "*_#{name}.rb")).any?
      end
    end
  end
end
