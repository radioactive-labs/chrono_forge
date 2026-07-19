require "chrono_forge"

require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use!

require "combustion"

# Activate strong_migrations before Combustion runs the gem's migrations, so an
# unsafe migration template (non-concurrent index, blocking column rewrite, etc.)
# raises StrongMigrations::UnsafeMigration during boot rather than shipping to
# users. strong_migrations only supports PostgreSQL/MySQL — on the default SQLite
# test DB it is a no-op (and noisy), so it is skipped there. The Postgres CI lane
# (DB_ADAPTER=postgresql) runs every gem migration under strong_migrations for
# real, failing the build on any unsafe migration.
require "strong_migrations"
StrongMigrations.skip_database(:primary) unless ENV["DB_ADAPTER"] == "postgresql"
# The secondary `chrono` database is always in-memory SQLite (even in the
# Postgres CI lane), where strong_migrations is unsupported and only warns.
StrongMigrations.skip_database(:chrono)

Combustion.path = "test/internal"
Combustion.initialize! :active_record, :active_job

require "chaotic_job"
