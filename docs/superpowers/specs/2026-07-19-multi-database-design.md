# Multi-database support + configurable UUID primary keys

Port angarium's multi-database feature to ChronoForge: let a host app keep
ChronoForge's tables in a separate database (a name from `config/database.yml`),
and make the primary key type explicit and configurable while still
auto-detecting UUID apps.

## Background

Angarium (a Rails engine) implements this as: `config.database` (simple case)
and `config.connects_to` (advanced roles/shards hash) applied via `connects_to`
in an abstract `Angarium::ApplicationRecord`; generators that install
migrations into `db/<name>_migrate` when a database is configured; and
`Angarium.primary_key_type` (explicit config → app's generators setting →
`:bigint`) used by every migration.

ChronoForge is a plain gem, not an engine. Its models currently inherit from
the host app's `::ApplicationRecord` via the `ChronoForge.ApplicationRecord()`
method, and migrations are copied into the host's `db/migrate` as templates.
UUID detection exists but is ad-hoc inline logic in the install migration
template (three defensive checks, one against an API that doesn't exist).

## Decisions made

- **Own abstract base class, always** — not just when a database is
  configured. Matches angarium; drops the host-`ApplicationRecord` coupling.
- **Angarium-style `primary_key_type` helper** — config override with
  generators-setting fallback, replacing the inline detection.
- **Full generator port** — `--database` flag on install and upgrade, plus a
  generated initializer (new to ChronoForge) documenting all config options.

## 1. Configuration (`lib/chrono_forge/configuration.rb`)

Add three accessors alongside the existing ones:

- `primary_key_type` — default `nil` (= auto-detect from the app).
- `database` — default `nil` (= primary connection). A database name from
  `config/database.yml`; drives both the connection and where the generators
  install migrations.
- `connects_to` — default `nil`. A hash passed straight to Rails' `connects_to`
  for custom roles/shards, e.g.
  `{ database: { writing: :chrono_forge, reading: :chrono_forge } }`. Wins over
  `database` for the connection.

Plus a `migrations_database` helper:
`database || connects_to&.dig(:database, :writing)` — the database the
generators should target; `nil` means the primary `db/migrate`.

## 2. Base record class (`lib/chrono_forge/application_record.rb`, new)

```ruby
module ChronoForge
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    if ChronoForge.config.connects_to
      connects_to(**ChronoForge.config.connects_to)
    elsif (db = ChronoForge.config.database)
      connects_to database: {writing: db, reading: db}
    end
  end
end
```

`Workflow`, `ExecutionLog`, and `ErrorLog` inherit from it. The
`ChronoForge.ApplicationRecord()` method is removed.

Timing: config is read once at class load. The gem's Zeitwerk loader autoloads
models lazily on first constant reference, and Rails eager-loads after
initializers run, so the setting is in place by then.

Behavior change: hosts whose `::ApplicationRecord` carried concerns (default
scopes, connection switching, etc.) no longer see them apply to ChronoForge
models. Needs a CHANGELOG note.

## 3. Primary key helper (`lib/chrono_forge.rb`)

```ruby
def self.primary_key_type
  config.primary_key_type ||
    Rails.application.config.generators.options.dig(:active_record, :primary_key_type) ||
    :bigint
end
```

The install migration template (`install_chrono_forge.rb`) replaces its inline
`primary_key_type` method with a call to `ChronoForge.primary_key_type` —
migrations run in the host app with initializers loaded, so the helper is
available and reflects config.

`add_chrono_forge_parent_execution_log` keeps reading the actual `id` column
type from the live schema: an upgrade migration must match what is physically
in the table, not current config.

## 4. Generators

### install

- Gains `--database NAME` (`-d`).
- Generates `config/initializers/chrono_forge.rb` from a new template with all
  options commented out and documented: `branch_merge_queue`, `max_duration`,
  `primary_key_type`, `database`, `connects_to`.
- With `--database`, uncomments/sets `config.database = :NAME` in the generated
  initializer (angarium's `gsub_file` approach), so later `upgrade` runs know
  the target without the flag.
- Copies migrations into `db/NAME_migrate` instead of `db/migrate` when a
  database is set (a database named `primary` still means `db/migrate`).
- Prints next steps: the `database.yml` stanza to add (with
  `migrations_paths: db/NAME_migrate`) and `bin/rails db:migrate:NAME`; or just
  `bin/rails db:migrate` in the single-db case.

### upgrade

- Same `--database` option, falling back to
  `ChronoForge.config.migrations_database`, so post-gem-upgrade migrations land
  in the right directory without re-passing the flag.

### MigrationActions

- The target directory becomes a parameter (`db/migrate` vs
  `db/<name>_migrate`); `chrono_forge_migration_exists?` checks that directory.

## 5. Tests

- `generators_test.rb`: install with and without `--database` (migration
  destination, initializer content, `config.database` line set), upgrade
  targeting via flag and via config fallback, idempotent re-runs.
- `ChronoForge.primary_key_type` precedence: explicit config > app generators
  setting > `:bigint`.
- `ApplicationRecord` wiring: with `config.database` set, `connects_to` is
  applied (assert on `connection_specification_name` / configured role hash);
  `connects_to` hash wins over `database`.
- Install migration produces uuid PKs and FKs when the app is configured for
  uuid.
- Existing suite continues to run against the internal app on the primary
  connection, unchanged.

## 6. Docs

- README: multi-database section (config, generator flag, database.yml stanza)
  and config reference updates.
- Docs site (`site/`): same content where configuration is documented.
- CHANGELOG: the base-class behavior change and the new config options.

## Out of scope

- Horizontal sharding beyond what a raw `connects_to` hash provides.
- Automatic `database.yml` editing (next-steps message only, like angarium).
- Changing the existing migration history or table schemas.
