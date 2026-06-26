# Branches (`branch` / `spawn` / `spawn_each` / `merge_branches`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a durable, large-scale fan-out/fan-in primitive to ChronoForge — `branch` blocks that `spawn`/`spawn_each` child sub-workflows and are joined by `merge_branches` (or `automerge`), built to dispatch hundreds of thousands of children per branch.

**Architecture:** A `branch :name do … end` block is a durable coordination step (`branch$<name>` execution log). Inside it, `spawn`/`spawn_each` eagerly create + bulk-enqueue child workflows (one `chrono_forge_workflows` row each, linked by a new generic `parent_execution_log_id` FK to the branch log). The block seals when it closes; `spawn_each` streams its source with a per-spawn cursor so dispatch resumes after a crash without re-streaming. Joining is poll-based via a lightweight `BranchMergeJob` (no parent replay per poll); branch/merge state is tracked in an in-memory registry (`@open_branches`) rebuilt each replay pass, so the completion gate can raise on a forgotten join.

**Tech Stack:** Ruby, ActiveJob (>= 7.1, for `perform_all_later`), ActiveRecord, Zeitwerk, Minitest + Combustion + ChaoticJob.

**User Verification:** NO — no user verification required (library feature; verified by the test suite).

**Reference spec:** `docs/superpowers/specs/2026-06-25-spawn-merge-branches-design.md`

---

## File Structure

**New library files**
- `lib/chrono_forge/executor/methods/branch.rb` — `branch`, `spawn`, `spawn_each`, and shared dispatch/cursor/registry helpers.
- `lib/chrono_forge/executor/methods/merge_branches.rb` — `merge_branches`/`merge_branch`, plus `branches_done?` / `enqueue_branch_merge_job` / `open_branch!` (used by the completion gate too).
- `lib/chrono_forge/branch_merge_job.rb` — `ChronoForge::BranchMergeJob`, the lightweight poller.
- `lib/generators/chrono_forge/templates/add_chrono_forge_parent_execution_log.rb` — additive migration.

**Modified library files**
- `lib/chrono_forge/executor.rb` — new error classes; `include Methods::Branch` / `Methods::MergeBranches` (via methods.rb); poll-cadence constants.
- `lib/chrono_forge/executor/methods.rb` — include the two new modules.
- `lib/chrono_forge/executor/methods/workflow_states.rb` — completion gate in `complete_workflow!`.
- `lib/chrono_forge/workflow.rb` — `belongs_to :parent_execution_log`.
- `lib/chrono_forge/execution_log.rb` — `has_many :spawned_workflows`.
- `lib/generators/chrono_forge/migration_actions.rb` — add migration to `MIGRATIONS`.
- `chrono_forge.gemspec` — `activejob >= 7.1` floor.
- `README.md` — branch/merge section + caveats.

**New/modified test files**
- `test/internal/db/migrate/20260626000001_add_chrono_forge_parent_execution_log.rb` — apply the column to the test DB.
- `test/internal/app/jobs/` — branch test workflow jobs + a trivial child workflow.
- `test/branch_test.rb`, `test/spawn_each_test.rb`, `test/branch_merge_job_test.rb`, `test/merge_branches_test.rb`, `test/automerge_test.rb`, `test/branch_recovery_test.rb`, `test/branch_scale_test.rb`.
- `test/schema_test.rb`, `test/generators_test.rb`, `test/upgrade_migration_test.rb` — extend for the new column/index.

---

### Task 1: Schema — `parent_execution_log_id` column + `(parent_execution_log_id, state)` index

**Goal:** Add a generic `parent_execution_log_id` FK column to `chrono_forge_workflows` with a composite index on `(parent_execution_log_id, state)`, shipped as an additive migration wired into the install/upgrade generators and applied to the test DB.

**Files:**
- Create: `lib/generators/chrono_forge/templates/add_chrono_forge_parent_execution_log.rb`
- Modify: `lib/generators/chrono_forge/migration_actions.rb`
- Create: `test/internal/db/migrate/20260626000001_add_chrono_forge_parent_execution_log.rb`
- Modify: `test/schema_test.rb`, `test/generators_test.rb`

**Acceptance Criteria:**
- [ ] `chrono_forge_workflows` has a nullable `parent_execution_log_id` column whose type matches the table's primary-key type (bigint or uuid).
- [ ] A composite index `(parent_execution_log_id, state)` exists.
- [ ] The migration is idempotent (`if_not_exists`) and listed in `MigrationActions::MIGRATIONS`.
- [ ] `generators_test` expects the new migration in the copied set.

**Verify:** `cd .worktrees/branches && bundle exec ruby -I test test/schema_test.rb` → all pass

**Steps:**

- [ ] **Step 1: Write the failing schema test**

Add to `test/schema_test.rb` (inside the existing `SchemaTest`):

```ruby
  def test_workflows_have_parent_execution_log_id_column
    assert connection.column_exists?(:chrono_forge_workflows, :parent_execution_log_id),
      "expected chrono_forge_workflows.parent_execution_log_id for branch children"
  end

  def test_workflows_have_parent_execution_log_state_index
    assert connection.index_exists?(:chrono_forge_workflows, %i[parent_execution_log_id state]),
      "expected composite index on [parent_execution_log_id, state] for the merge probe"
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec ruby -I test test/schema_test.rb -n test_workflows_have_parent_execution_log_id_column`
Expected: FAIL — column does not exist.

- [ ] **Step 3: Write the migration template**

Create `lib/generators/chrono_forge/templates/add_chrono_forge_parent_execution_log.rb`:

```ruby
# frozen_string_literal: true

# Adds chrono_forge_workflows.parent_execution_log_id: the execution log that
# spawned a workflow (for branches, the branch$<name> log). Deliberately generic
# so any future step that spawns sub-workflows can reuse it. The composite
# [parent_execution_log_id, state] index makes the merge completion probe and the
# dropped-job re-kick index-only at hundreds of thousands of children.
#
# Shipped standalone (matching add_chrono_forge_workflow_state_index) so existing
# installs pick it up via `rails generate chrono_forge:upgrade`.
class AddChronoForgeParentExecutionLog < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_column :chrono_forge_workflows, :parent_execution_log_id, parent_log_fk_type,
      null: true, if_not_exists: true

    add_index :chrono_forge_workflows, %i[parent_execution_log_id state],
      if_not_exists: true, **chrono_forge_index_algorithm
  end

  private

  # Match the type of chrono_forge_workflows.id so the FK lines up on both bigint
  # and uuid installs.
  def parent_log_fk_type
    id_col = connection.columns(:chrono_forge_workflows).find { |c| c.name == "id" }
    id_col && id_col.sql_type.to_s.downcase.include?("uuid") ? :uuid : :bigint
  end

  def chrono_forge_index_algorithm
    if connection.adapter_name.to_s.downcase.include?("postgresql")
      {algorithm: :concurrently}
    else
      {}
    end
  end
end
```

- [ ] **Step 4: Wire it into the generators**

In `lib/generators/chrono_forge/migration_actions.rb`, append to `MIGRATIONS`:

```ruby
      MIGRATIONS = %w[
        install_chrono_forge
        add_chrono_forge_workflow_state_index
        add_chrono_forge_error_log_step_context
        add_chrono_forge_parent_execution_log
      ].freeze
```

Update `test/generators_test.rb` `test_install_copies_all_migrations` expected list to include `"add_chrono_forge_parent_execution_log.rb"` (keep it alphabetically sorted as the test sorts), and bump the idempotence count in `test_install_is_idempotent` from `3` to `4`.

- [ ] **Step 5: Apply to the test DB**

Create `test/internal/db/migrate/20260626000001_add_chrono_forge_parent_execution_log.rb` with the **same class body** as the template (Combustion runs these migrations to build the test schema):

```ruby
# frozen_string_literal: true

require_relative "../../../../lib/generators/chrono_forge/templates/add_chrono_forge_parent_execution_log"
```

(If the `require_relative` shortcut causes Combustion load-order issues, instead paste the full class body from Step 3 into this file verbatim.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec ruby -I test test/schema_test.rb && bundle exec ruby -I test test/generators_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/generators test/internal/db/migrate test/schema_test.rb test/generators_test.rb
git commit -m "feat(branches): add parent_execution_log_id column + index"
```

```json:metadata
{"files": ["lib/generators/chrono_forge/templates/add_chrono_forge_parent_execution_log.rb", "lib/generators/chrono_forge/migration_actions.rb", "test/internal/db/migrate/20260626000001_add_chrono_forge_parent_execution_log.rb", "test/schema_test.rb", "test/generators_test.rb"], "verifyCommand": "bundle exec ruby -I test test/schema_test.rb", "acceptanceCriteria": ["parent_execution_log_id column exists", "composite (parent_execution_log_id, state) index exists", "migration listed in MIGRATIONS and generators_test"], "requiresUserVerification": false}
```

---

### Task 2: Model associations

**Goal:** Link children to their spawning branch log via ActiveRecord associations.

**Files:**
- Modify: `lib/chrono_forge/workflow.rb`
- Modify: `lib/chrono_forge/execution_log.rb`
- Test: `test/branch_associations_test.rb`

**Acceptance Criteria:**
- [ ] `Workflow#parent_execution_log` returns the spawning `ExecutionLog` (optional).
- [ ] `ExecutionLog#spawned_workflows` returns the workflows it spawned.

**Verify:** `bundle exec ruby -I test test/branch_associations_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write the failing test**

Create `test/branch_associations_test.rb`:

```ruby
require "test_helper"

class BranchAssociationsTest < ActiveJob::TestCase
  def test_parent_execution_log_and_spawned_workflows_round_trip
    parent = ChronoForge::Workflow.create!(key: "p-#{SecureRandom.hex}", job_class: "X")
    log = parent.execution_logs.create!(step_name: "branch$grp")
    child = ChronoForge::Workflow.create!(
      key: "c-#{SecureRandom.hex}", job_class: "Y", parent_execution_log_id: log.id
    )

    assert_equal log, child.parent_execution_log
    assert_includes log.spawned_workflows, child
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec ruby -I test test/branch_associations_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'parent_execution_log'`.

- [ ] **Step 3: Add the associations**

In `lib/chrono_forge/workflow.rb`, after `has_many :error_logs, dependent: :destroy`:

```ruby
    belongs_to :parent_execution_log,
      class_name: "ChronoForge::ExecutionLog", optional: true
```

In `lib/chrono_forge/execution_log.rb`, after `belongs_to :workflow`:

```ruby
    has_many :spawned_workflows,
      class_name: "ChronoForge::Workflow",
      foreign_key: :parent_execution_log_id,
      inverse_of: :parent_execution_log,
      dependent: :nullify
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec ruby -I test test/branch_associations_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/chrono_forge/workflow.rb lib/chrono_forge/execution_log.rb test/branch_associations_test.rb
git commit -m "feat(branches): parent_execution_log / spawned_workflows associations"
```

```json:metadata
{"files": ["lib/chrono_forge/workflow.rb", "lib/chrono_forge/execution_log.rb", "test/branch_associations_test.rb"], "verifyCommand": "bundle exec ruby -I test test/branch_associations_test.rb", "acceptanceCriteria": ["parent_execution_log association", "spawned_workflows association"], "requiresUserVerification": false}
```

---

### Task 3: `branch` + `spawn` (block, registry, eager single dispatch, seal, skip-on-replay)

**Goal:** Implement the `branch` block (durable step, in-memory registry, seal-on-close, **skip-the-block-when-sealed**) and `spawn` (single eager child dispatch). `spawn` outside a branch raises.

**Files:**
- Create: `lib/chrono_forge/executor/methods/branch.rb`
- Modify: `lib/chrono_forge/executor.rb` (error classes)
- Modify: `lib/chrono_forge/executor/methods.rb` (include)
- Create: `test/internal/app/jobs/single_spawn_workflow.rb`, `test/internal/app/jobs/noop_child.rb`
- Create: `test/branch_test.rb`

**Acceptance Criteria:**
- [ ] `branch :g do spawn :c, NoopChild end` creates a child with key `"<parent.key>$g$c"`, `job_class: "NoopChild"`, `parent_execution_log_id` = the `branch$g` log id, `state: idle`.
- [ ] The `branch$g` log is `completed` (sealed) after the block closes.
- [ ] On replay (sealed), the block body is **not** re-executed (no duplicate child rows, no re-dispatch).
- [ ] `spawn` called outside a `branch` block raises `NotInBranchError`.

**Verify:** `bundle exec ruby -I test test/branch_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write failing tests + fixtures**

Create `test/internal/app/jobs/noop_child.rb`:

```ruby
class NoopChild < WorkflowJob
  prepend ChronoForge::Executor

  def perform(**)
    durably_execute :noop
  end

  private

  def noop = nil
end
```

Create `test/internal/app/jobs/single_spawn_workflow.rb`:

```ruby
class SingleSpawnWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    branch :grp, automerge: true do
      spawn :child, NoopChild, foo: "bar"
    end
  end
end
```

Create `test/branch_test.rb`:

```ruby
require "test_helper"

class BranchTest < ActiveJob::TestCase
  def test_spawn_creates_linked_child_and_seals_branch
    SingleSpawnWorkflow.perform_later("ss-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "ss-1")
    branch_log = parent.execution_logs.find_by(step_name: "branch$grp")
    assert branch_log.completed?, "branch should seal when the block closes"

    child = ChronoForge::Workflow.find_by(key: "ss-1$grp$child")
    assert child, "child should be created with deterministic key"
    assert_equal "NoopChild", child.job_class
    assert_equal branch_log.id, child.parent_execution_log_id
    assert_equal({"foo" => "bar"}, child.kwargs)
  end

  def test_spawn_outside_branch_raises
    workflow = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      def perform = spawn(:x, NoopChild)
    end
    Object.const_set(:BareSpawnWorkflow, workflow)
    BareSpawnWorkflow.perform_later("bare-1")
    assert_raises(ChronoForge::Executor::NotInBranchError) { perform_all_jobs }
  ensure
    Object.send(:remove_const, :BareSpawnWorkflow) if defined?(BareSpawnWorkflow)
  end

  def test_sealed_branch_block_is_not_re_executed_on_replay
    # First run dispatches + seals.
    SingleSpawnWorkflow.perform_later("ss-2")
    perform_all_jobs
    branch_log = ChronoForge::Workflow.find_by(key: "ss-2").execution_logs.find_by(step_name: "branch$grp")

    # Re-run the same workflow key: the sealed branch must skip its block.
    inserts = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*a|
      inserts += 1 if /INSERT INTO ["`]?chrono_forge_workflows/i.match?(a.last[:sql].to_s)
    end
    SingleSpawnWorkflow.perform_later("ss-2")
    perform_all_jobs
    ActiveSupport::Notifications.unsubscribe(sub)

    assert_equal 0, inserts, "sealed branch must not re-dispatch children on replay"
    assert_equal 1, ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id).count
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec ruby -I test test/branch_test.rb`
Expected: FAIL — `NameError: uninitialized constant ... NotInBranchError` / `NoMethodError: branch`.

- [ ] **Step 3: Add the error classes**

In `lib/chrono_forge/executor.rb`, after `class InvalidStepName < NotExecutableError; end`:

```ruby
    # spawn/spawn_each called outside a branch block. NotExecutableError so it
    # propagates (fail-fast on a programming error) rather than being retried.
    class NotInBranchError < NotExecutableError; end

    # A branch was opened but neither merged via merge_branches nor declared
    # automerge: true. Raised at the completion gate. Fail-fast (not retried).
    class UnmergedBranchError < NotExecutableError; end
```

- [ ] **Step 4: Implement `branch` + `spawn` + shared helpers**

Create `lib/chrono_forge/executor/methods/branch.rb`:

```ruby
module ChronoForge
  module Executor
    module Methods
      module Branch
        # Opens a named branch — a durable fan-out step. Spawns inside the block
        # eagerly create + enqueue child workflows; the branch SEALS when the
        # block closes. Returns without waiting (branches are concurrent; the
        # join is a separate merge_branches / automerge).
        def branch(name, automerge: false)
          raise ArgumentError, "branch requires a block" unless block_given?
          raise ArgumentError, "branch blocks cannot be nested" if @current_branch
          validate_step_name_segment!(name)

          step_name = "branch$#{name}"
          log = find_or_create_execution_log!(step_name) { |l| l.started_at = Time.current }

          # The sealed branch log may be a readonly, id-less cache stand-in; fetch
          # the real id so the registry/merge can scope children to it.
          log_id = log.id || ExecutionLog.where(workflow: @workflow, step_name: step_name).pick(:id)
          (@open_branches ||= {})[name.to_s] = {automerge: automerge, log_id: log_id}

          # ---- THE single most important correctness/performance property ----
          # A SEALED branch skips its block ENTIRELY. The expensive source
          # enumeration in spawn_each never re-runs after sealing. Do not move
          # dispatch out from behind this guard.
          unless log.completed?
            @current_branch = {name: name.to_s, log: log, seq: 0}
            begin
              yield
            ensure
              @current_branch = nil
            end
            log.update!(state: :completed, completed_at: Time.current)
          end

          name
        end

        # Dispatch a single child into the current branch.
        def spawn(name, workflow_class, **kwargs)
          cb = current_branch!
          validate_step_name_segment!(name)
          child_key = "#{@workflow.key}$#{cb[:name]}$#{name}"
          dispatch_children(cb, [[child_key, workflow_class, kwargs]])
          name
        end

        private

        def current_branch!
          @current_branch || raise(NotInBranchError, "spawn/spawn_each may only be called inside a branch block")
        end

        # Bulk-create child workflow rows then bulk-enqueue their jobs.
        # perform_all_later bypasses the class-level perform_later guard, so we
        # validate the args ourselves before enqueuing.
        def dispatch_children(cb, entries)
          return if entries.empty?
          now = Time.current
          rows = entries.map do |child_key, klass, kwargs|
            validate_child_enqueue!(child_key, kwargs)
            {
              key: child_key, job_class: klass.to_s,
              kwargs: kwargs, options: {}, context: {},
              state: Workflow.states[:idle],
              parent_execution_log_id: cb[:log].id,
              created_at: now, updated_at: now
            }
          end
          # On-conflict-ignore makes re-dispatch (crash recovery) idempotent.
          Workflow.insert_all(rows, unique_by: :key)
          jobs = entries.map { |child_key, klass, kwargs| klass.new(child_key, **kwargs) }
          ActiveJob.perform_all_later(jobs)
        end

        def validate_child_enqueue!(child_key, kwargs)
          unless child_key.is_a?(String)
            raise ArgumentError, "child key must be a String (got #{child_key.inspect})"
          end
          reserved = kwargs.keys.map(&:to_sym) & RESERVED_KWARGS
          if reserved.any?
            raise ArgumentError, "#{reserved.join(", ")} are reserved ChronoForge keywords"
          end
        end

        # Advance (and persist) a spawn_each cursor on the branch log.
        # `n` is the running item index; `pk` is the AR keyset position (nil for
        # plain enumerables).
        def advance_cursor!(cb, spawn_name, n:, pk: nil)
          meta = cb[:log].metadata || {}
          cursors = meta["cursors"] || {}
          entry = cursors[spawn_name.to_s] || {}
          entry["n"] = n
          entry["pk"] = pk unless pk.nil?
          cursors[spawn_name.to_s] = entry
          meta["cursors"] = cursors
          cb[:log].update!(metadata: meta)
        end
      end
    end
  end
end
```

In `lib/chrono_forge/executor/methods.rb`, add the include (place `Branch` before `WorkflowStates` so its private helpers are available to the completion gate):

```ruby
module ChronoForge
  module Executor
    module Methods
      include Methods::Wait
      include Methods::WaitUntil
      include Methods::ContinueIf
      include Methods::DurablyExecute
      include Methods::DurablyRepeat
      include Methods::Branch
      include Methods::MergeBranches
      include Methods::WorkflowStates
    end
  end
end
```

> Note: `Methods::MergeBranches` is referenced here but created in Task 6. Until then, add a temporary empty module to keep the suite loading, OR implement Task 6 immediately after this task. The subagent executing this plan should create `merge_branches.rb` with at least `module ChronoForge; module Executor; module Methods; module MergeBranches; end; end; end; end` now and flesh it out in Task 6.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec ruby -I test test/branch_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/chrono_forge test/internal/app/jobs/noop_child.rb test/internal/app/jobs/single_spawn_workflow.rb test/branch_test.rb
git commit -m "feat(branches): branch block + spawn single child"
```

```json:metadata
{"files": ["lib/chrono_forge/executor/methods/branch.rb", "lib/chrono_forge/executor.rb", "lib/chrono_forge/executor/methods.rb", "test/branch_test.rb", "test/internal/app/jobs/noop_child.rb", "test/internal/app/jobs/single_spawn_workflow.rb"], "verifyCommand": "bundle exec ruby -I test test/branch_test.rb", "acceptanceCriteria": ["spawn creates linked child + seals branch", "spawn outside branch raises NotInBranchError", "sealed branch skips block on replay"], "requiresUserVerification": false}
```

---

### Task 4: `spawn_each` — streaming bulk dispatch with cursor

**Goal:** Implement `spawn_each(name, source, of:)` — stream an AR relation (keyset) or any enumerable, dispatching one child per item keyed `name_{index}`, with the class returned from the block and a resumable per-spawn cursor. Raise on a conflicting AR `.order`.

**Files:**
- Modify: `lib/chrono_forge/executor/methods/branch.rb`
- Create: `test/internal/app/jobs/spawn_each_workflow.rb`
- Create: `test/spawn_each_test.rb`

**Acceptance Criteria:**
- [ ] `spawn_each :items, User.all` over N users creates N children keyed `<parent.key>$grp$items_0 … items_{N-1}`, each `parent_execution_log_id` = the branch log.
- [ ] The block's returned class is honored per item (mixed classes supported).
- [ ] An AR relation with an explicit conflicting `.order(...)` raises (via `error_on_ignore: true`).
- [ ] A plain enumerable source works (offset cursor).
- [ ] Cursor `{ "pk" =>, "n" => }` is persisted under `metadata.cursors[name]`.

**Verify:** `bundle exec ruby -I test test/spawn_each_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write failing tests + fixtures**

Create `test/internal/app/jobs/spawn_each_workflow.rb`:

```ruby
class SpawnEachWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform(of: 1000)
    branch :grp, automerge: true do
      spawn_each :items, User.order(:id), of: of do |user|
        [NoopChild, {user_id: user.id}]
      end
    end
  end
end
```

Create `test/spawn_each_test.rb`:

```ruby
require "test_helper"

class SpawnEachTest < ActiveJob::TestCase
  def setup
    User.delete_all
    @users = 5.times.map { |i| User.create!(name: "u#{i}", email: "u#{i}@e.com") }
  end

  def test_spawn_each_creates_one_indexed_child_per_item
    SpawnEachWorkflow.perform_later("se-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "se-1")
    branch_log = parent.execution_logs.find_by(step_name: "branch$grp")
    children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id).order(:key)

    assert_equal 5, children.count
    assert_equal (0..4).map { |i| "se-1$grp$items_#{i}" }, children.pluck(:key)
    assert_equal [@users.first.id], [children.first.kwargs["user_id"]]
    cursor = branch_log.reload.metadata["cursors"]["items"]
    assert_equal 5, cursor["n"]
  end

  def test_spawn_each_honors_class_from_block
    klass = Class.new(WorkflowJob) { prepend ChronoForge::Executor; def perform(**) = nil }
    Object.const_set(:AltChild, klass)
    job = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      def perform
        branch(:g, automerge: true) do
          spawn_each(:i, User.order(:id)) { |u| u.id.even? ? [AltChild, {id: u.id}] : [NoopChild, {id: u.id}] }
        end
      end
    end
    Object.const_set(:MixedClassWorkflow, job)

    MixedClassWorkflow.perform_later("mc-1")
    perform_all_jobs

    classes = ChronoForge::Workflow.where("key LIKE ?", "mc-1$g$i_%").pluck(:job_class).uniq.sort
    assert_equal %w[AltChild NoopChild], classes
  ensure
    Object.send(:remove_const, :AltChild) if defined?(AltChild)
    Object.send(:remove_const, :MixedClassWorkflow) if defined?(MixedClassWorkflow)
  end

  def test_spawn_each_raises_on_conflicting_order
    job = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      def perform
        branch(:g, automerge: true) do
          spawn_each(:i, User.order(:email)) { |u| [NoopChild, {id: u.id}] }
        end
      end
    end
    Object.const_set(:BadOrderWorkflow, job)
    BadOrderWorkflow.perform_later("bo-1")
    assert_raises(ActiveRecord::IrreversibleOrderError) { perform_all_jobs }
  ensure
    Object.send(:remove_const, :BadOrderWorkflow) if defined?(BadOrderWorkflow)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec ruby -I test test/spawn_each_test.rb`
Expected: FAIL — `NoMethodError: spawn_each`.

- [ ] **Step 3: Implement `spawn_each`**

Add to `lib/chrono_forge/executor/methods/branch.rb` (in module `Branch`, public, next to `spawn`):

```ruby
        # Dispatch one child per item of `source`, streamed. AR relations use
        # keyset iteration (in_batches start:) for constant memory; any other
        # enumerable uses an offset cursor. Items are keyed `name_{index}` by
        # their sequential position, so the source must re-enumerate identically
        # across replays. The block returns [WorkflowClass, kwargs] (or a class).
        def spawn_each(name, source, of: 1000)
          cb = current_branch!
          validate_step_name_segment!(name)
          cursor = (cb[:log].metadata&.dig("cursors", name.to_s)) || {}
          n = (cursor["n"] || 0)

          if source.is_a?(ActiveRecord::Relation)
            source.find_in_batches(batch_size: of, start: cursor["pk"], error_on_ignore: true) do |records|
              entries = records.map do |record|
                klass, kw = normalize_spawn(yield(record))
                ck = "#{@workflow.key}$#{cb[:name]}$#{name}_#{n}"
                n += 1
                [ck, klass, kw]
              end
              dispatch_children(cb, entries)
              advance_cursor!(cb, name, pk: records.last.id, n: n)
            end
          else
            source.drop(n).each_slice(of) do |slice|
              entries = slice.map do |item|
                klass, kw = normalize_spawn(yield(item))
                ck = "#{@workflow.key}$#{cb[:name]}$#{name}_#{n}"
                n += 1
                [ck, klass, kw]
              end
              dispatch_children(cb, entries)
              advance_cursor!(cb, name, n: n)
            end
          end
          name
        end
```

And the private helper (add near the other privates in `Branch`):

```ruby
        # Normalize the block return: [Klass, kwargs] or a bare Klass.
        def normalize_spawn(result)
          klass, kwargs = Array(result)
          [klass, kwargs || {}]
        end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec ruby -I test test/spawn_each_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/chrono_forge/executor/methods/branch.rb test/spawn_each_test.rb test/internal/app/jobs/spawn_each_workflow.rb
git commit -m "feat(branches): spawn_each streaming bulk dispatch with cursor"
```

```json:metadata
{"files": ["lib/chrono_forge/executor/methods/branch.rb", "test/spawn_each_test.rb", "test/internal/app/jobs/spawn_each_workflow.rb"], "verifyCommand": "bundle exec ruby -I test test/spawn_each_test.rb", "acceptanceCriteria": ["one indexed child per item", "class from block honored (mixed)", "raises on conflicting AR order", "cursor persisted"], "requiresUserVerification": false}
```

---

### Task 5: `BranchMergeJob` — the lightweight poller

**Goal:** Implement the dedicated poller: capped-count probe per branch, wake the parent when all branches are sealed + drained, otherwise re-kick dropped jobs and reschedule with an adaptive (capped-count) interval.

**Files:**
- Create: `lib/chrono_forge/branch_merge_job.rb`
- Modify: `lib/chrono_forge/executor.rb` (poll-cadence constants — optional, can live on the job)
- Create: `test/branch_merge_job_test.rb`

**Acceptance Criteria:**
- [ ] When every branch log is `completed` (sealed) and has zero incomplete children, the job enqueues the parent workflow (`parent_job_class.perform_later(parent_key)`) and does not reschedule.
- [ ] Otherwise it reschedules itself with delay `clamp(pending * FACTOR, min, max)` and does not wake the parent.
- [ ] The pending count is capped at `CAP` (never counts beyond it).
- [ ] A never-started child (`started_at` nil) older than the re-kick threshold is re-enqueued.

**Verify:** `bundle exec ruby -I test test/branch_merge_job_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write failing tests**

Create `test/branch_merge_job_test.rb`:

```ruby
require "test_helper"

class BranchMergeJobTest < ActiveJob::TestCase
  def setup
    @parent = ChronoForge::Workflow.create!(key: "bmj-parent", job_class: "SingleSpawnWorkflow")
    @log = @parent.execution_logs.create!(step_name: "branch$g", state: :completed)
  end

  def child!(state:, started_at: Time.current)
    ChronoForge::Workflow.create!(
      key: "c-#{SecureRandom.hex}", job_class: "NoopChild",
      parent_execution_log_id: @log.id, state: state, started_at: started_at
    )
  end

  def test_wakes_parent_when_all_complete
    child!(state: :completed)
    assert_enqueued_with(job: SingleSpawnWorkflow, args: ["bmj-parent"]) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  def test_reschedules_when_incomplete
    child!(state: :running)
    assert_enqueued_with(job: ChronoForge::BranchMergeJob) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
    refute_enqueued_with(job: SingleSpawnWorkflow)
  end

  def test_rekicks_never_started_child
    stuck = child!(state: :idle, started_at: nil)
    stuck.update_column(:updated_at, 10.minutes.ago)
    assert_enqueued_with(job: NoopChild, args: ["#{stuck.key}"]) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec ruby -I test test/branch_merge_job_test.rb`
Expected: FAIL — `NameError: uninitialized constant ChronoForge::BranchMergeJob`.

- [ ] **Step 3: Implement the poller**

Create `lib/chrono_forge/branch_merge_job.rb`:

```ruby
module ChronoForge
  # Lightweight poller that joins one or more branches. NOT a workflow — it holds
  # no lock, does no replay, and carries no context. It exists so the heavy parent
  # workflow is replayed only twice per merge (kick off + completion wake).
  class BranchMergeJob < ActiveJob::Base
    CAP = 5_000          # cap the pending count; beyond it we just pick max_interval
    FACTOR = 0.06        # seconds of delay per pending child
    REKICK_AFTER = 5.minutes

    def perform(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval)
      pending = branch_log_ids.sum { |id| incomplete_scope(id).limit(CAP).count }
      sealed = branch_log_ids.all? { |id| branch_sealed?(id) }

      if sealed && pending.zero?
        parent_job_class.constantize.perform_later(parent_key)
        return
      end

      rekick_dropped_jobs(branch_log_ids)

      delay = [[pending * FACTOR, min_interval].max, max_interval].min
      self.class.set(wait: delay.seconds)
        .perform_later(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval)
    end

    private

    def incomplete_scope(branch_log_id)
      Workflow.where(parent_execution_log_id: branch_log_id)
        .where.not(state: Workflow.states[:completed])
    end

    def branch_sealed?(branch_log_id)
      ExecutionLog.where(id: branch_log_id, state: ExecutionLog.states[:completed]).exists?
    end

    # A child dispatched but never run (its job was dropped by the backend) is
    # re-enqueued. started_at IS NULL can't distinguish "never enqueued" from
    # "queued but not yet picked up", so we only re-kick children that have been
    # idle past REKICK_AFTER. Re-enqueue is idempotent: a completed/running child
    # no-ops via the executable?/lock guard.
    def rekick_dropped_jobs(branch_log_ids)
      branch_log_ids.each do |id|
        Workflow.where(parent_execution_log_id: id, started_at: nil)
          .where("updated_at < ?", REKICK_AFTER.ago)
          .find_each do |child|
            child.job_klass.perform_later(child.key, **child.kwargs.symbolize_keys)
          end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec ruby -I test test/branch_merge_job_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/chrono_forge/branch_merge_job.rb test/branch_merge_job_test.rb
git commit -m "feat(branches): BranchMergeJob lightweight poller"
```

```json:metadata
{"files": ["lib/chrono_forge/branch_merge_job.rb", "test/branch_merge_job_test.rb"], "verifyCommand": "bundle exec ruby -I test test/branch_merge_job_test.rb", "acceptanceCriteria": ["wakes parent when all complete", "reschedules when incomplete", "capped count", "re-kicks never-started child"], "requiresUserVerification": false}
```

---

### Task 6: `merge_branches` / `merge_branch` — the join

**Goal:** Implement `merge_branches(*names)` (alias `merge_branch`): immediate done-check, else enqueue `BranchMergeJob` and halt; remove joined branches from `@open_branches` on completion; raise on an unopened name. Provide the shared helpers (`branches_done?`, `enqueue_branch_merge_job`, `open_branch!`) used by the completion gate in Task 7.

**Files:**
- Modify: `lib/chrono_forge/executor/methods/merge_branches.rb`
- Create: `test/merge_branches_test.rb`
- Create: `test/internal/app/jobs/two_branch_workflow.rb`

**Acceptance Criteria:**
- [ ] After all children of the named branches complete, the parent resumes and the `merge$<names>` log is `completed`.
- [ ] While children are incomplete, the parent halts (idle) and a `BranchMergeJob` is enqueued.
- [ ] A failed/stalled child keeps the parent parked (Option A); recovering it lets the merge resolve.
- [ ] `merge_branches :never_opened` raises `ArgumentError`.

**Verify:** `bundle exec ruby -I test test/merge_branches_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write failing tests + fixture**

Create `test/internal/app/jobs/two_branch_workflow.rb`:

```ruby
class TwoBranchWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    branch :a do
      spawn :one, NoopChild
    end
    branch :b do
      spawn :two, NoopChild
    end
    merge_branches :a, :b
    durably_execute :finalize
  end

  private

  def finalize
    context["finalized"] = true
  end
end
```

Create `test/merge_branches_test.rb`:

```ruby
require "test_helper"

class MergeBranchesTest < ActiveJob::TestCase
  def test_parent_resumes_after_branches_complete
    TwoBranchWorkflow.perform_later("mb-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "mb-1")
    assert parent.completed?, "parent should complete once both branches merge"
    assert_equal true, parent.context["finalized"]
    merge_log = parent.execution_logs.find { |l| l.step_name.start_with?("merge$") }
    assert merge_log.completed?
  end

  def test_unopened_branch_name_raises
    job = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      def perform = merge_branches(:nope)
    end
    Object.const_set(:NoBranchMergeWorkflow, job)
    NoBranchMergeWorkflow.perform_later("nb-1")
    assert_raises(ArgumentError) { perform_all_jobs }
  ensure
    Object.send(:remove_const, :NoBranchMergeWorkflow) if defined?(NoBranchMergeWorkflow)
  end

  # Option A: a non-completed (stalled) child keeps the parent parked; recovering
  # the child lets the merge resolve.
  def test_failed_child_parks_parent_until_recovered
    StalledChildBranchWorkflow.perform_later("oa-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "oa-1")
    child = ChronoForge::Workflow.find_by(key: "oa-1$grp$c")
    refute parent.completed?, "parent must stay parked while child is not completed"
    assert child.stalled?, "child should be stalled (permanent failure)"

    # Recover the child; drive jobs again — the merge poll should now resolve.
    child.context # no-op touch
    child.update!(state: :idle) # simulate fix + allow re-run
    StalledChildBranchWorkflow::ALLOW_COMPLETE[:ok] = true
    child.retry_later rescue child.job_klass.perform_later(child.key)
    perform_all_jobs

    assert ChronoForge::Workflow.find_by(key: "oa-1").completed?,
      "parent should complete once the recovered child completes"
  end
end
```

And add the stalling fixture `test/internal/app/jobs/stalled_child_branch_workflow.rb`:

```ruby
class StalledChildBranchWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  # Toggled by the test to let the child succeed on recovery.
  ALLOW_COMPLETE = {ok: false}

  def perform
    branch :grp do
      spawn :c, StalledChild
    end
    merge_branches :grp
  end
end

class StalledChild < WorkflowJob
  prepend ChronoForge::Executor

  def perform(**)
    durably_execute :maybe_fail, retry_policy: ChronoForge::Executor::RetryPolicy.new(retry_on: [])
  end

  private

  def maybe_fail
    raise "not yet" unless StalledChildBranchWorkflow::ALLOW_COMPLETE[:ok]
  end
end
```

> The exact recovery mechanics (`retry_later` vs re-enqueue, the `ALLOW_COMPLETE` toggle) may need adjusting against the real stall/retry behaviour observed in `test/chrono_forge_test.rb`'s permanent-failure tests — the assertion that matters is **parent parked while child not completed, parent completes after child completes**. Mirror the permanent-failure pattern already used in `chrono_forge_test.rb` for the stall setup.

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec ruby -I test test/merge_branches_test.rb`
Expected: FAIL — `NoMethodError: merge_branches`.

- [ ] **Step 3: Implement `merge_branches` + helpers**

Replace the placeholder `lib/chrono_forge/executor/methods/merge_branches.rb` with:

```ruby
module ChronoForge
  module Executor
    module Methods
      module MergeBranches
        # Join one or more named branches. Separate from dispatch so branches run
        # concurrently. Does one immediate check; if not done, hands off to the
        # lightweight BranchMergeJob and halts (the heavy parent is not replayed
        # per poll). Default cadence clamps between min/max, scaled by pending.
        def merge_branches(*names, min_interval: 5.seconds, max_interval: 5.minutes)
          step_name = "merge$#{names.map(&:to_s).sort.join(",")}"
          log = find_or_create_execution_log!(step_name) { |l| l.started_at = Time.current }
          return if log.completed?

          branch_log_ids = names.map { |nm| open_branch!(nm)[:log_id] }

          if branches_done?(branch_log_ids)
            names.each { |nm| @open_branches.delete(nm.to_s) }
            log.update!(state: :completed, completed_at: Time.current)
            return
          end

          enqueue_branch_merge_job(branch_log_ids, min_interval, max_interval)
          halt_execution!
        end
        alias_method :merge_branch, :merge_branches

        private

        def open_branch!(name)
          (@open_branches || {}).fetch(name.to_s) do
            raise ArgumentError, "no open branch named #{name.inspect} (open it with `branch #{name.inspect} do … end` first)"
          end
        end

        # A branch is done when its log is sealed (completed) and it has no
        # incomplete children. exists? short-circuits at the first incomplete row.
        def branches_done?(branch_log_ids)
          branch_log_ids.all? do |id|
            next false unless ExecutionLog.where(id: id, state: ExecutionLog.states[:completed]).exists?
            !Workflow.where(parent_execution_log_id: id)
              .where.not(state: Workflow.states[:completed]).exists?
          end
        end

        def enqueue_branch_merge_job(branch_log_ids, min_interval, max_interval)
          BranchMergeJob.perform_later(
            @workflow.key, self.class.to_s, branch_log_ids,
            min_interval.to_i, max_interval.to_i
          )
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec ruby -I test test/merge_branches_test.rb`
Expected: PASS.

- [ ] **Step 5: Run the full suite to catch regressions**

Run: `bundle exec rake test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/chrono_forge/executor/methods/merge_branches.rb test/merge_branches_test.rb test/internal/app/jobs/two_branch_workflow.rb
git commit -m "feat(branches): merge_branches poll-join"
```

```json:metadata
{"files": ["lib/chrono_forge/executor/methods/merge_branches.rb", "test/merge_branches_test.rb", "test/internal/app/jobs/two_branch_workflow.rb"], "verifyCommand": "bundle exec ruby -I test test/merge_branches_test.rb", "acceptanceCriteria": ["parent resumes after branches complete", "halts + enqueues poller while incomplete", "unopened name raises"], "requiresUserVerification": false}
```

---

### Task 7: Completion gate — automerge + raise on unmerged

**Goal:** In `complete_workflow!`, before sealing, inspect `@open_branches`: raise `UnmergedBranchError` for any leftover non-automerge branch; for leftover automerge branches, join them (poll/halt) before completing.

**Files:**
- Modify: `lib/chrono_forge/executor/methods/workflow_states.rb`
- Create: `test/automerge_test.rb`

**Acceptance Criteria:**
- [ ] An `automerge: true` branch with no `merge_branches` blocks workflow completion until its children finish, then completes.
- [ ] A branch opened with neither `merge_branches` nor `automerge: true` raises `UnmergedBranchError` at completion (even if its children already finished).
- [ ] A branch already joined via `merge_branches` does not re-trigger at the gate.

**Verify:** `bundle exec ruby -I test test/automerge_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write failing tests + fixture**

Create `test/internal/app/jobs/unmerged_branch_workflow.rb`:

```ruby
class UnmergedBranchWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    branch :forgotten do            # no automerge, never merged
      spawn :c, NoopChild
    end
  end
end
```

Create `test/automerge_test.rb`:

```ruby
require "test_helper"

class AutomergeTest < ActiveJob::TestCase
  # SingleSpawnWorkflow opens branch :grp with automerge: true and no merge.
  def test_automerge_blocks_completion_until_children_done
    SingleSpawnWorkflow.perform_later("am-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "am-1")
    assert parent.completed?, "automerge branch should be joined before completion"
    child = ChronoForge::Workflow.find_by(key: "am-1$grp$child")
    assert child.completed?
  end

  def test_unmerged_branch_raises
    UnmergedBranchWorkflow.perform_later("um-1")
    error = assert_raises(ChronoForge::Executor::UnmergedBranchError) { perform_all_jobs }
    assert_match(/forgotten/, error.message)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec ruby -I test test/automerge_test.rb`
Expected: `test_unmerged_branch_raises` FAILS (no error raised — branch silently detached).

- [ ] **Step 3: Add the completion gate**

In `lib/chrono_forge/executor/methods/workflow_states.rb`, change the start of `complete_workflow!` to call the gate first:

```ruby
        def complete_workflow!
          enforce_branch_joins!

          # Create an execution log for workflow completion
          execution_log = find_or_create_execution_log!("$workflow_completion$") do |log|
            log.started_at = Time.current
          end
          # ... unchanged body ...
```

Add the private gate method to the `WorkflowStates` module (it uses `branches_done?` / `enqueue_branch_merge_job` from `MergeBranches`, available on the same instance):

```ruby
        # Every branch must be joined — explicitly (merge_branches) or implicitly
        # (automerge: true). @open_branches is the in-memory registry rebuilt each
        # replay pass: branch adds, merge_branches removes on completion. Anything
        # left here is either an automerge branch to join, or a forgotten join.
        def enforce_branch_joins!
          open = @open_branches || {}
          return if open.empty?

          unmerged = open.reject { |_, b| b[:automerge] }
          if unmerged.any?
            names = unmerged.keys
            raise UnmergedBranchError,
              "branch(es) #{names.join(", ")} were opened but never merged. " \
              "Add `merge_branches #{names.map { |n| ":#{n}" }.join(", ")}` " \
              "or open with `branch(..., automerge: true)`."
          end

          auto_ids = open.values.map { |b| b[:log_id] }
          unless branches_done?(auto_ids)
            enqueue_branch_merge_job(auto_ids, 5.seconds, 5.minutes)
            halt_execution!   # poller wakes the parent; the gate re-runs on replay
          end
        end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec ruby -I test test/automerge_test.rb`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rake test`
Expected: all green (confirm KitchenSink etc. — which open no branches — are unaffected; `enforce_branch_joins!` returns early when `@open_branches` is empty).

- [ ] **Step 6: Commit**

```bash
git add lib/chrono_forge/executor/methods/workflow_states.rb test/automerge_test.rb test/internal/app/jobs/unmerged_branch_workflow.rb
git commit -m "feat(branches): completion gate — automerge + raise on unmerged"
```

```json:metadata
{"files": ["lib/chrono_forge/executor/methods/workflow_states.rb", "test/automerge_test.rb", "test/internal/app/jobs/unmerged_branch_workflow.rb"], "verifyCommand": "bundle exec ruby -I test test/automerge_test.rb", "acceptanceCriteria": ["automerge blocks completion until children done", "unmerged branch raises", "already-merged branch is a no-op at gate"], "requiresUserVerification": false}
```

---

### Task 8: Crash-recovery (cursor resume) + scale/perf regression tests

**Goal:** Prove dispatch resumes from the cursor after a mid-dispatch crash (no duplicate children, bounded rework), and that dispatch is `⌈N/of⌉` inserts (not N) with constant per-item work.

**Files:**
- Create: `test/branch_recovery_test.rb`
- Create: `test/branch_scale_test.rb`

**Acceptance Criteria:**
- [ ] A crash after chunk *k* leaves `metadata.cursors[name]` at that point; the resumed run continues from it, ends with exactly N children, no duplicate keys.
- [ ] Dispatching N children with batch size `of` issues `⌈N/of⌉` `INSERT INTO chrono_forge_workflows` statements (not N).

**Verify:** `bundle exec ruby -I test test/branch_recovery_test.rb test/branch_scale_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write the scale test**

Create `test/branch_scale_test.rb`:

```ruby
require "test_helper"

class BranchScaleTest < ActiveJob::TestCase
  def setup
    User.delete_all
    25.times { |i| User.create!(name: "u#{i}", email: "u#{i}@e.com") }
  end

  def test_dispatch_uses_bulk_inserts_not_one_per_child
    inserts = 0
    pattern = /INSERT INTO ["`]?chrono_forge_workflows/i
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*a|
      inserts += 1 if pattern.match?(a.last[:sql].to_s)
    end
    # of: 10 over 25 users => ceil(25/10) = 3 insert_all statements.
    SpawnEachWorkflow.perform_later("scale-1", of: 10)
    perform_all_jobs_before(1.second) # dispatch happens on the first pass
    ActiveSupport::Notifications.unsubscribe(sub)

    branch_log = ChronoForge::Workflow.find_by(key: "scale-1").execution_logs.find_by(step_name: "branch$grp")
    assert_equal 25, ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id).count
    assert_operator inserts, :<=, 3, "expected <= ceil(25/10) bulk inserts, got #{inserts}"
  end
end
```

> Note: this asserts on **`insert_all`** (DB rows), which is always bulk. Do NOT assert bulk job *enqueue* — under the test adapter `perform_all_later` falls back to per-job enqueue.

- [ ] **Step 2: Write the recovery test**

Create `test/branch_recovery_test.rb`:

```ruby
require "test_helper"

class BranchRecoveryTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    User.delete_all
    25.times { |i| User.create!(name: "u#{i}", email: "u#{i}@e.com") }
  end

  def test_resumes_dispatch_from_cursor_after_glitch
    # Glitch once during dispatch; ChaoticJob re-runs the workflow, which must
    # resume spawn_each from the persisted cursor rather than restarting at 0.
    workflow = SpawnEachWorkflow.new("rec-1", of: 10)
    run_scenario(workflow, glitch: ["before", "#{ChronoForge::Executor::Methods::Branch.instance_method(:dispatch_children).source_location[0]}:#{dispatch_children_line}"])

    branch_log = ChronoForge::Workflow.find_by(key: "rec-1").execution_logs.find_by(step_name: "branch$grp")
    children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id)
    assert_equal 25, children.count, "exactly N children, no duplicates after resume"
    assert_equal 25, children.distinct.count(:key)
  end

  private

  # Resolve the line of the perform_all_later call inside dispatch_children so the
  # glitch lands mid-dispatch. Adjust if the method changes.
  def dispatch_children_line
    src = File.read(ChronoForge::Executor::Methods::Branch.instance_method(:dispatch_children).source_location[0])
    src.lines.index { |l| l.include?("perform_all_later") }.to_i + 1
  end
end
```

> If targeting an exact glitch line proves brittle, an acceptable alternative is to call `SpawnEachWorkflow.perform_later` twice in a row with the same key (simulating a re-run) after manually truncating `metadata.cursors` to a mid-point, and assert the final child set is exactly N with no duplicates. Either approach proves cursor-resume idempotency.

- [ ] **Step 3: Run both to verify they fail, then pass**

Run: `bundle exec ruby -I test test/branch_scale_test.rb test/branch_recovery_test.rb`
Expected: PASS (these exercise Task 3/4 code; if they fail, fix the dispatch/cursor logic, not the tests).

- [ ] **Step 4: Commit**

```bash
git add test/branch_recovery_test.rb test/branch_scale_test.rb
git commit -m "test(branches): cursor-resume recovery + bulk-dispatch scale guards"
```

```json:metadata
{"files": ["test/branch_recovery_test.rb", "test/branch_scale_test.rb"], "verifyCommand": "bundle exec ruby -I test test/branch_scale_test.rb test/branch_recovery_test.rb", "acceptanceCriteria": ["cursor resume: exactly N children no dupes", "dispatch uses ceil(N/of) bulk inserts"], "requiresUserVerification": false}
```

---

### Task 9: Dependency floor + README

**Goal:** Pin `activejob >= 7.1` (required for `perform_all_later`) and document the feature with the load-bearing caveats.

**Files:**
- Modify: `chrono_forge.gemspec`
- Modify: `README.md`

**Acceptance Criteria:**
- [ ] `chrono_forge.gemspec` requires `activejob >= 7.1`.
- [ ] README has a "Branches" section documenting `branch`/`spawn`/`spawn_each`/`merge_branches`/`automerge` and the three caveats (every branch must be joined; parent not replayed per poll; source must be stable during dispatch).

**Verify:** `bundle exec ruby -e "require 'rubygems'; spec = Gem::Specification.load('chrono_forge.gemspec'); dep = spec.dependencies.find { |d| d.name == 'activejob' }; abort('no floor') unless dep.requirement.satisfied_by?(Gem::Version.new('7.1')) && !dep.requirement.satisfied_by?(Gem::Version.new('7.0')); puts 'ok'"` → `ok`

**Steps:**

- [ ] **Step 1: Pin the dependency**

In `chrono_forge.gemspec`, change:

```ruby
  spec.add_dependency "activejob"
```

to:

```ruby
  spec.add_dependency "activejob", ">= 7.1"
```

- [ ] **Step 2: Document in README**

Add a "Branches: parallel sub-workflows" section to `README.md` with a worked example (the `branch :fulfillment, automerge: true do … end` + `merge_branches` example from the spec's Goal section) and a "Caveats" callout covering, verbatim in spirit:
- Every branch must be merged or `automerge: true`, else `UnmergedBranchError`.
- The heavy parent is not replayed per poll — a lightweight `BranchMergeJob` does the waiting.
- The source must be stable during a branch's dispatch window (items keyed `name_{index}` by position; `error_on_ignore: true` catches ordering, not insertion).

- [ ] **Step 3: Verify the gemspec floor**

Run the Verify command above. Expected: `ok`.

- [ ] **Step 4: Run the full suite one last time**

Run: `bundle exec rake test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add chrono_forge.gemspec README.md
git commit -m "feat(branches): require activejob >= 7.1; document branches"
```

```json:metadata
{"files": ["chrono_forge.gemspec", "README.md"], "verifyCommand": "bundle exec rake test", "acceptanceCriteria": ["activejob >= 7.1 floor", "README branches section + caveats"], "requiresUserVerification": false}
```

---

## Notes for the implementer

- **Zeitwerk loading:** new files under `lib/chrono_forge/` autoload by namespace — `branch_merge_job.rb` → `ChronoForge::BranchMergeJob`; `executor/methods/branch.rb` → `ChronoForge::Executor::Methods::Branch`. No manual `require`. The only wiring is the `include`s in `executor/methods.rb`.
- **Helper visibility:** `branch.rb`, `merge_branches.rb`, and `workflow_states.rb` are all mixed into the same `Executor` instance, so their private helpers (`dispatch_children`, `branches_done?`, `enqueue_branch_merge_job`, `current_branch!`) call each other freely.
- **`insert_all` + JSON:** pass `kwargs`/`options`/`context` as Ruby hashes; Rails casts them to the json/jsonb columns. `insert_all` does not set timestamps — `created_at`/`updated_at` are set explicitly in `dispatch_children`.
- **Child execution on first run:** `dispatch_children` pre-inserts the child row (with `kwargs`), then enqueues `klass.new(child_key, **kwargs)`. When the child job runs, the executor's `setup_workflow!` finds the pre-inserted row and uses its stored `kwargs` — the job-arg kwargs are redundant but harmless.
- **Run order:** Tasks 1→2→3→4 are strictly sequential; 5 depends on 2; 6 depends on 5 and 3; 7 depends on 6 and 3/4; 8 depends on 7; 9 is independent. The `MergeBranches` module must exist (even empty) once Task 3 wires the include — create the file in Task 3, flesh it out in Task 6.
