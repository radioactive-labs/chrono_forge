# Multi-Database + Configurable UUID PKs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a host app keep ChronoForge's tables in a separate database (`config.database` / `config.connects_to`), with an explicit-but-auto-detecting primary key type (`ChronoForge.primary_key_type`).

**Architecture:** Port angarium's design into ChronoForge's non-engine structure: new config accessors + a `migrations_database` helper; a new abstract `ChronoForge::ApplicationRecord < ActiveRecord::Base` that applies `connects_to` at class load (replacing inheritance from the host's `::ApplicationRecord`); generators gain `--database NAME` and install migrations into `db/NAME_migrate`; install additionally generates a documented initializer.

**Tech Stack:** Ruby gem (Zeitwerk, ActiveRecord ≥ 7.1), Rails generators (Thor), Minitest + Combustion test app (`test/internal`), standardrb.

**User Verification:** NO — no user verification required.

**Spec:** `docs/superpowers/specs/2026-07-19-multi-database-design.md`

**⚠️ Commits:** Per the user's global instructions, do NOT stage or commit unless the user explicitly asks. Task boundaries below are natural commit points — offer to commit at the end instead.

**Verify (whole plan):** `bundle exec rake` (runs tests + standard) from the repo root. Note the memory: a fresh worktree needs the git-ignored `Gemfile.lock` copied in from the main checkout or tests won't run.

## File Structure

- `lib/chrono_forge/configuration.rb` — add `primary_key_type`, `database`, `connects_to` accessors + `migrations_database`
- `lib/chrono_forge.rb` — add `ChronoForge.primary_key_type`; remove `ChronoForge.ApplicationRecord()`
- `lib/chrono_forge/application_record.rb` (new) — abstract base class, applies `connects_to`
- `lib/chrono_forge/{workflow,execution_log,error_log}.rb` — inherit `ApplicationRecord`
- `lib/generators/chrono_forge/templates/install_chrono_forge.rb` — use `ChronoForge.primary_key_type`
- `lib/generators/chrono_forge/migration_actions.rb` — shared `--database` option + target-dir logic
- `lib/generators/chrono_forge/install/install_generator.rb` — initializer + next-steps
- `lib/generators/chrono_forge/upgrade/upgrade_generator.rb` — desc update (option comes from MigrationActions)
- `lib/generators/chrono_forge/templates/initializer.rb` (new) — documented initializer template
- `test/multi_db_config_test.rb`, `test/application_record_test.rb` (new), `test/generators_test.rb` (extend)
- `README.md` — multi-database section

---

### Task 1: Configuration accessors + `ChronoForge.primary_key_type`

**Goal:** New config surface (`primary_key_type`, `database`, `connects_to`, `migrations_database`) and the PK resolution helper.

**Files:**
- Modify: `lib/chrono_forge/configuration.rb`
- Modify: `lib/chrono_forge.rb`
- Test: `test/multi_db_config_test.rb` (new)

**Acceptance Criteria:**
- [ ] `ChronoForge.primary_key_type` precedence: explicit config → app `config.generators` setting → `:bigint`
- [ ] `config.migrations_database` returns `database`, else the `connects_to` writing role, else nil
- [ ] Works when `Rails` is undefined (gem has no railties dependency)

**Verify:** `bundle exec rake test TEST=test/multi_db_config_test.rb` → all pass

**Steps:**

- [ ] **Step 1: Write the failing tests**

Create `test/multi_db_config_test.rb`:

```ruby
require "test_helper"

class MultiDbConfigTest < ActiveJob::TestCase
  def teardown
    ChronoForge.reset_configuration!
    Rails.application.config.generators.options[:active_record].delete(:primary_key_type)
  end

  def test_primary_key_type_defaults_to_bigint
    assert_equal :bigint, ChronoForge.primary_key_type
  end

  def test_explicit_primary_key_type_wins
    ChronoForge.configure { |c| c.primary_key_type = :uuid }
    assert_equal :uuid, ChronoForge.primary_key_type
  end

  def test_primary_key_type_falls_back_to_app_generators_setting
    Rails.application.config.generators.options[:active_record][:primary_key_type] = :uuid
    assert_equal :uuid, ChronoForge.primary_key_type
  end

  def test_explicit_config_beats_app_generators_setting
    Rails.application.config.generators.options[:active_record][:primary_key_type] = :uuid
    ChronoForge.configure { |c| c.primary_key_type = :bigint }
    assert_equal :bigint, ChronoForge.primary_key_type
  end

  def test_migrations_database_nil_by_default
    assert_nil ChronoForge.config.migrations_database
  end

  def test_migrations_database_prefers_explicit_database
    ChronoForge.configure do |c|
      c.database = :chrono
      c.connects_to = {database: {writing: :other, reading: :other}}
    end
    assert_equal :chrono, ChronoForge.config.migrations_database
  end

  def test_migrations_database_derives_from_connects_to_writing_role
    ChronoForge.configure { |c| c.connects_to = {database: {writing: :chrono, reading: :replica}} }
    assert_equal :chrono, ChronoForge.config.migrations_database
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rake test TEST=test/multi_db_config_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'primary_key_type'`

- [ ] **Step 3: Implement configuration accessors**

In `lib/chrono_forge/configuration.rb`, after the `attr_accessor :max_duration` block, add:

```ruby
    # Primary key type for ChronoForge's own tables, used by the install
    # migration. nil (default) auto-detects: the app's config.generators
    # primary_key_type if set, else :bigint. Set :uuid etc. to force.
    attr_accessor :primary_key_type

    # Multi-database: the database (a key from config/database.yml) that
    # ChronoForge's tables live in. Drives both the models' connection and
    # where the generators install migrations (db/<database>_migrate).
    # nil (default) keeps ChronoForge on the app's primary connection.
    attr_accessor :database

    # Advanced multi-database: a hash passed straight to Rails' connects_to
    # for custom roles/shards, e.g.
    # { database: { writing: :chrono_forge, reading: :chrono_forge } }.
    # Takes precedence over database for the connection.
    attr_accessor :connects_to
```

In `initialize`, add:

```ruby
      @primary_key_type = nil
      @database = nil
      @connects_to = nil
```

After `reap_stale_after`/`attr_writer`, add:

```ruby
    # The database ChronoForge's migrations belong in, for the generators.
    # Prefers the explicit database, else the writing role from a connects_to
    # hash. nil => the app's primary db/migrate.
    def migrations_database
      database || connects_to&.dig(:database, :writing)
    end
```

- [ ] **Step 4: Implement `ChronoForge.primary_key_type`**

In `lib/chrono_forge.rb`, after `def self.configure`, add:

```ruby
  # Primary key type for ChronoForge's own tables. Explicit config wins;
  # otherwise respect the app's global generators setting; otherwise Rails'
  # default (bigint).
  def self.primary_key_type
    config.primary_key_type || app_generators_primary_key_type || :bigint
  end

  # The host app's config.generators primary_key_type, when running inside a
  # booted Rails app (the gem itself does not depend on railties).
  def self.app_generators_primary_key_type
    return unless defined?(Rails) && Rails.application

    Rails.application.config.generators.options.dig(:active_record, :primary_key_type)
  end
  private_class_method :app_generators_primary_key_type
```

- [ ] **Step 5: Run to verify pass**

Run: `bundle exec rake test TEST=test/multi_db_config_test.rb`
Expected: PASS (7 tests)

---

### Task 2: `ChronoForge::ApplicationRecord` base class

**Goal:** Own abstract base class applying `connects_to` from config; models stop inheriting the host's `::ApplicationRecord`.

**Files:**
- Create: `lib/chrono_forge/application_record.rb`
- Modify: `lib/chrono_forge/workflow.rb:29`, `lib/chrono_forge/execution_log.rb:31`, `lib/chrono_forge/error_log.rb:28` (the `class X < ApplicationRecord()` lines)
- Modify: `lib/chrono_forge.rb` (remove `def self.ApplicationRecord`)
- Test: `test/application_record_test.rb` (new)

**Acceptance Criteria:**
- [ ] All three models inherit `ChronoForge::ApplicationRecord` (abstract, `< ActiveRecord::Base`)
- [ ] `connects_to_settings` derives `{database: {writing:, reading:}}` from `config.database`; raw `config.connects_to` wins
- [ ] Default config → nil (primary connection); full existing suite still green

**Verify:** `bundle exec rake test` → all pass

**Steps:**

- [ ] **Step 1: Write the failing tests**

Create `test/application_record_test.rb`:

```ruby
require "test_helper"

class ApplicationRecordTest < ActiveJob::TestCase
  def teardown
    ChronoForge.reset_configuration!
  end

  def test_models_inherit_from_chrono_forge_application_record
    [ChronoForge::Workflow, ChronoForge::ExecutionLog, ChronoForge::ErrorLog].each do |model|
      assert_equal ChronoForge::ApplicationRecord, model.superclass,
        "#{model} should inherit ChronoForge::ApplicationRecord"
    end
  end

  def test_application_record_is_abstract
    assert ChronoForge::ApplicationRecord.abstract_class?
  end

  def test_no_connects_to_settings_by_default
    assert_nil ChronoForge::ApplicationRecord.connects_to_settings
  end

  def test_database_config_derives_writing_and_reading_roles
    ChronoForge.configure { |c| c.database = :chrono_forge }
    assert_equal({database: {writing: :chrono_forge, reading: :chrono_forge}},
      ChronoForge::ApplicationRecord.connects_to_settings)
  end

  def test_connects_to_config_wins_over_database
    ChronoForge.configure do |c|
      c.database = :ignored
      c.connects_to = {database: {writing: :w, reading: :r}}
    end
    assert_equal({database: {writing: :w, reading: :r}},
      ChronoForge::ApplicationRecord.connects_to_settings)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rake test TEST=test/application_record_test.rb`
Expected: FAIL — `NameError: uninitialized constant ChronoForge::ApplicationRecord` (Zeitwerk finds no file)

- [ ] **Step 3: Create the base class**

Create `lib/chrono_forge/application_record.rb`:

```ruby
# frozen_string_literal: true

module ChronoForge
  # Abstract base class for all ChronoForge models.
  #
  # Multi-database support: point every ChronoForge table at a separate
  # database instead of the app's primary connection. The host sets either
  # config.database (a database name; the common case) or config.connects_to
  # (a raw hash for custom roles/shards, which wins if both are set). Read
  # once here at class load: initializers run before these models are first
  # referenced (Zeitwerk autoloads them lazily), so the setting is in place.
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    # The connects_to settings implied by the configuration, or nil when
    # ChronoForge stays on the app's primary connection. A method rather than
    # inline logic below so the derivation is testable without reconnecting.
    def self.connects_to_settings(config = ChronoForge.config)
      if config.connects_to
        config.connects_to
      elsif config.database
        {database: {writing: config.database, reading: config.database}}
      end
    end

    if (settings = connects_to_settings)
      connects_to(**settings)
    end
  end
end
```

- [ ] **Step 4: Switch the models over**

In `lib/chrono_forge/workflow.rb`, `lib/chrono_forge/execution_log.rb`, and `lib/chrono_forge/error_log.rb`, change each class line:

```ruby
# before
class Workflow < ApplicationRecord()
# after
class Workflow < ApplicationRecord
```

(same for `ExecutionLog` and `ErrorLog` — the bare constant resolves to `ChronoForge::ApplicationRecord` inside the module).

In `lib/chrono_forge.rb`, delete the line:

```ruby
  def self.ApplicationRecord = defined?(::ApplicationRecord) ? ::ApplicationRecord : ActiveRecord::Base
```

- [ ] **Step 5: Run the FULL suite**

Run: `bundle exec rake test`
Expected: PASS — the internal Combustion app has no `::ApplicationRecord`, so behavior in tests is unchanged; this catches any stray `ApplicationRecord()` caller.

---

### Task 3: Install migration template uses `ChronoForge.primary_key_type`

**Goal:** Replace the 25-line inline detection in the install migration with the helper.

**Files:**
- Modify: `lib/generators/chrono_forge/templates/install_chrono_forge.rb:74-99`
- Test: add one test to `test/multi_db_config_test.rb`

**Acceptance Criteria:**
- [ ] Template's private `primary_key_type` delegates to `ChronoForge.primary_key_type`
- [ ] With `config.primary_key_type = :uuid`, the migration resolves `:uuid`
- [ ] Combustion boot (which runs this template via `test/internal/db/migrate`) still green

**Verify:** `bundle exec rake test TEST=test/multi_db_config_test.rb` and full `bundle exec rake test`

**Steps:**

- [ ] **Step 1: Write the failing test**

Add to `test/multi_db_config_test.rb`:

```ruby
  def test_install_migration_uses_configured_primary_key_type
    ChronoForge.configure { |c| c.primary_key_type = :uuid }
    assert_equal :uuid, InstallChronoForge.new.send(:primary_key_type),
      "install migration should resolve its PK type via ChronoForge.primary_key_type"
  end
```

(`InstallChronoForge` is already loaded: `test/internal/db/migrate/20241217100623_install_chrono_forge.rb` requires the template at Combustion boot.)

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rake test TEST=test/multi_db_config_test.rb`
Expected: FAIL — the old inline detection returns `:bigint` (it never reads ChronoForge config)

- [ ] **Step 3: Replace the inline detection**

In `lib/generators/chrono_forge/templates/install_chrono_forge.rb`, replace the entire `private` section (the `primary_key_type` method, lines 74–99) with:

```ruby
  private

  # Explicit config wins; otherwise the app's config.generators setting;
  # otherwise :bigint. See ChronoForge.primary_key_type.
  def primary_key_type
    ChronoForge.primary_key_type
  end
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rake test TEST=test/multi_db_config_test.rb` → PASS
Then: `bundle exec rake test` → PASS (Combustion re-runs the template at boot)

---

### Task 4: Generators — `--database`, `db/NAME_migrate`, initializer

**Goal:** Install/upgrade route migrations to `db/NAME_migrate` when a database is configured (flag or config), and install generates a documented initializer recording `--database`.

**Files:**
- Modify: `lib/generators/chrono_forge/migration_actions.rb`
- Modify: `lib/generators/chrono_forge/install/install_generator.rb`
- Modify: `lib/generators/chrono_forge/upgrade/upgrade_generator.rb`
- Create: `lib/generators/chrono_forge/templates/initializer.rb`
- Test: `test/generators_test.rb`

**Acceptance Criteria:**
- [ ] `install --database=chrono` → 4 migrations in `db/chrono_migrate`, none in `db/migrate`, initializer contains active `config.database = :chrono`
- [ ] Plain `install` → migrations in `db/migrate`, initializer generated with everything commented out
- [ ] `upgrade` with `ChronoForge.config.database = :chrono` (no flag) targets `db/chrono_migrate`; skips existing
- [ ] Existing generator tests still pass; `--database=primary` behaves like no flag (dir-wise)

**Verify:** `bundle exec rake test TEST=test/generators_test.rb` → all pass

**Steps:**

- [ ] **Step 1: Write the failing tests**

In `test/generators_test.rb`, change `run_generator` to accept args:

```ruby
  def run_generator(klass, dir, args = [])
    silence_stream($stdout) { klass.start(args, destination_root: dir) }
  end
```

Add tests:

```ruby
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rake test TEST=test/generators_test.rb`
Expected: FAIL — unknown `--database` option / missing initializer

- [ ] **Step 3: Parametrize MigrationActions**

Replace the body of `lib/generators/chrono_forge/migration_actions.rb`'s module (keep the file comment and `MIGRATIONS`) with:

```ruby
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
                "(defaults to config.database / connects_to)"
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
        (db.nil? || db.to_s == "primary") ? "db/migrate" : "db/#{db}_migrate"
      end

      def chrono_forge_database
        options[:database].presence || ChronoForge.config.migrations_database
      end

      def chrono_forge_migration_exists?(name)
        Dir.glob(File.join(destination_root, chrono_forge_migrations_dir, "*_#{name}.rb")).any?
      end
    end
```

(Included-module methods do not become Thor commands — only methods defined directly in the generator class do — so these helpers stay out of the run sequence, same as today.)

- [ ] **Step 4: Create the initializer template**

Create `lib/generators/chrono_forge/templates/initializer.rb`:

```ruby
ChronoForge.configure do |config|
  # ActiveJob queue for the branch-merge poller (BranchMergeJob). For large
  # fan-outs, point this at a dedicated queue with its own worker so the
  # poller is not starved behind the branch's own children.
  # config.branch_merge_queue = :default

  # How long a single workflow pass may hold its lock before another job may
  # steal it (the assumed maximum duration of one execution pass).
  # config.max_duration = 10.minutes

  # Age past which a workflow still in :running is treated as stranded and
  # re-enqueued by ChronoForge::Workflow.reap_stalled. Defaults to 3x max_duration.
  # config.reap_stale_after = 30.minutes

  # Primary key type for ChronoForge's own tables.
  # config.primary_key_type = nil # nil = auto-detect (app's generators setting, else :bigint); set :uuid etc. to force

  # Multi-database: keep ChronoForge's tables in their own database. Set this
  # to a database name from config/database.yml and ChronoForge routes all its
  # models and migrations there. `bin/rails g chrono_forge:install --database=NAME`
  # sets this for you; a later `chrono_forge:upgrade` run reads it so new
  # migrations still land in db/NAME_migrate. nil (default) uses the primary
  # connection.
  # config.database = :chrono_forge
  #
  # Advanced: for custom roles/shards, pass a hash straight to Rails'
  # connects_to. It wins over config.database for the connection (set
  # config.database too so the generators know where to install migrations).
  # config.connects_to = { database: { writing: :chrono_forge, reading: :chrono_forge } }
end
```

- [ ] **Step 5: Rework the install generator**

Replace `lib/generators/chrono_forge/install/install_generator.rb` content:

```ruby
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
    # target the right directory without the flag.
    def set_database_config
      return unless options[:database]

      gsub_file "config/initializers/chrono_forge.rb", /^\s*#?\s*config\.database\s*=.*$/,
        %(  config.database = :#{options[:database]})
    end

    def copy_migrations
      copy_chrono_forge_migrations
    rescue => err
      say "#{err.class}: #{err}\n#{err.backtrace.join("\n")}", :red
      exit 1
    end

    def print_next_steps
      db = chrono_forge_database
      if db && chrono_forge_migrations_dir != "db/migrate"
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
```

- [ ] **Step 6: Update the upgrade generator's docs**

In `lib/generators/chrono_forge/upgrade/upgrade_generator.rb`, no structural change (it inherits the `--database` option via `MigrationActions.included`). Update the class comment to mention multi-db, e.g. append to the existing comment:

```ruby
  # Multi-database aware: with --database (or config.database set in the
  # initializer), missing migrations are copied into db/NAME_migrate.
```

- [ ] **Step 7: Run to verify pass**

Run: `bundle exec rake test TEST=test/generators_test.rb`
Expected: PASS — new tests plus the three pre-existing tests (plain install still targets `db/migrate`; the old idempotency test counts only `db/migrate/*.rb`, unaffected by the new initializer).

---

### Task 5: Documentation + final verification

**Goal:** README documents multi-database + PK config; full suite and linter green.

**Files:**
- Modify: `README.md` (Installation section, ~line 145)
- Check: `site/index.html` (mirror only if it documents the install command)

**Acceptance Criteria:**
- [ ] README has a "Multi-database" subsection: `--database` flag, database.yml stanza with `migrations_paths`, `config.database`/`config.connects_to`, `config.primary_key_type`, and a note that ChronoForge models no longer inherit the host's `ApplicationRecord`
- [ ] `bundle exec rake` fully green (tests + standard)

**Verify:** `bundle exec rake` → 0 failures, standard clean

**Steps:**

- [ ] **Step 1: Add README section**

In `README.md`, inside the Installation section (after the generator/migrate instructions, before "Upgrading"), add:

```markdown
### Multi-database

ChronoForge can keep its tables in a separate database. Install with:

```shell
rails generate chrono_forge:install --database=chrono_forge
```

This sets `config.database = :chrono_forge` in `config/initializers/chrono_forge.rb`
and installs the migrations into `db/chrono_forge_migrate`. Add the database to
`config/database.yml` (per environment):

```yaml
chrono_forge:
  <<: *default
  database: myapp_chrono_forge
  migrations_paths: db/chrono_forge_migrate
```

then run `bin/rails db:migrate:chrono_forge`. Later `rails generate chrono_forge:upgrade`
runs read `config.database`, so new migrations land in the right place automatically.

For custom roles or shards, pass a hash straight to Rails' `connects_to`
(it wins over `config.database` for the connection):

```ruby
ChronoForge.configure do |config|
  config.connects_to = { database: { writing: :chrono_forge, reading: :chrono_forge } }
end
```

#### Primary keys

ChronoForge's tables use your app's primary key type automatically: if
`config.generators` sets `primary_key_type: :uuid`, the install migration
creates UUID keys. Override explicitly with `config.primary_key_type = :uuid`
(or `:bigint`) in the initializer.

> **Note:** ChronoForge models inherit from `ChronoForge::ApplicationRecord`
> (their own abstract base class), not from your app's `ApplicationRecord`.
```

- [ ] **Step 2: Check the docs site**

Run: `grep -n "chrono_forge:install\|configure" site/index.html`
If the site documents installation/configuration, add one sentence mentioning `--database=NAME` for multi-db setups next to the install command, matching the surrounding HTML structure. If it doesn't, skip.

- [ ] **Step 3: Full verification**

Run: `bundle exec rake`
Expected: all tests pass, standard reports no offenses.

- [ ] **Step 4: Offer commits to the user**

Do not commit. Summarize the changes and ask the user whether they want them committed (their global config requires explicit instruction). Suggested message if they say yes: `feat: multi-database support and configurable primary key type` with a body noting the `ApplicationRecord` base-class behavior change.
