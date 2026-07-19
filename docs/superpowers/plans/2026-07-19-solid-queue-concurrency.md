# Automatic SolidQueue Concurrency Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `ChronoForge::Executor` is prepended and SolidQueue's `limits_concurrency` is available, automatically apply a per-workflow-key concurrency limit (semaphore key `"<Class>/<key>"`, duration `max_duration + 5.seconds`).

**Architecture:** One guard in `Executor.prepended` calls `base.limits_concurrency` when `ChronoForge.config.concurrency_control` (new accessor, default true) is set and the class responds to the API. SolidQueue's default concurrency group (the class name) provides class scoping for free; `to: 1` / `on_conflict: :block` defaults are kept. ChronoForge's `LockStrategy` remains the correctness layer; this is dispatch-time efficiency.

**Tech Stack:** Ruby gem, ActiveJob, minitest + Combustion (`test/internal` host app, workflow fixtures subclass `WorkflowJob`). No solid_queue dependency — tests stub the macro. Spec: `docs/superpowers/specs/2026-07-19-solid-queue-concurrency-design.md`.

**User Verification:** NO — no user verification required.

**Commit policy note:** Commits below happen only on `feature/solid-queue-concurrency` inside this worktree. Nothing is merged or pushed without the user's say-so (user's global preference).

---

### Task 1: Config accessor + automatic limits_concurrency in Executor.prepended, with tests

**Goal:** `ChronoForge.config.concurrency_control` (default true) gates an automatic `base.limits_concurrency(key: ->(key, **) { key }, duration: max_duration + 5.seconds)` call in `Executor.prepended`.

**Files:**
- Modify: `lib/chrono_forge/configuration.rb` (accessor + default)
- Modify: `lib/chrono_forge/executor.rb:42` (`self.prepended` — add guard before `base.class_attribute`)
- Test: `test/concurrency_control_test.rb` (new)

**Acceptance Criteria:**
- [ ] `ChronoForge::Configuration.new.concurrency_control == true`
- [ ] Prepending into a class that responds to `limits_concurrency` calls it with a key proc returning the first positional arg and `duration == max_duration + 5.seconds`; `to:`/`on_conflict:`/`group:` are NOT passed (SolidQueue defaults apply)
- [ ] With `config.concurrency_control = false`, no call is made
- [ ] Prepending into a class without `limits_concurrency` raises nothing and workflows still run
- [ ] Full suite + standardrb pass

**Verify:** `bundle exec rake test TEST=test/concurrency_control_test.rb` → 0 failures; then `bundle exec rake` → 0 failures, standard clean

**Steps:**

- [ ] **Step 1: Write the failing test**

Create `test/concurrency_control_test.rb`:

```ruby
require "test_helper"

# Automatic SolidQueue concurrency control: Executor.prepended applies a
# per-workflow-key limits_concurrency when the class supports it (spec:
# docs/superpowers/specs/2026-07-19-solid-queue-concurrency-design.md).
# solid_queue is not a dependency; FakeConcurrencyControls mimics its
# ActiveJob macro and records the arguments.
class ConcurrencyControlTest < ActiveJob::TestCase
  module FakeConcurrencyControls
    attr_reader :concurrency_args

    def limits_concurrency(**opts)
      @concurrency_args = opts
    end
  end

  def test_configuration_defaults_to_enabled
    assert_equal true, ChronoForge::Configuration.new.concurrency_control
  end

  def test_prepend_applies_per_key_limit_when_api_available
    klass = Class.new(WorkflowJob) do
      extend FakeConcurrencyControls
      prepend ChronoForge::Executor
    end

    args = klass.concurrency_args
    refute_nil args, "expected limits_concurrency to be called"
    assert_equal ChronoForge.config.max_duration + 5.seconds, args[:duration]
    # to:/on_conflict:/group: must fall through to SolidQueue defaults
    assert_equal %i[duration key], args.keys.sort
  end

  def test_key_proc_returns_workflow_key_ignoring_kwargs
    klass = Class.new(WorkflowJob) do
      extend FakeConcurrencyControls
      prepend ChronoForge::Executor
    end

    # SolidQueue instance_execs the proc with the job's arguments; the workflow
    # key is the sole positional on every enqueue path.
    assert_equal "order-123", klass.concurrency_args[:key].call("order-123", foo: 1)
  end

  def test_prepend_skips_when_disabled
    ChronoForge.config.concurrency_control = false
    klass = Class.new(WorkflowJob) do
      extend FakeConcurrencyControls
      prepend ChronoForge::Executor
    end

    assert_nil klass.concurrency_args
  ensure
    ChronoForge.config.concurrency_control = true
  end

  def test_prepend_is_inert_without_the_api
    klass = Class.new(WorkflowJob) { prepend ChronoForge::Executor }

    refute klass.respond_to?(:limits_concurrency)
    assert klass.respond_to?(:perform_later) # prepend completed normally
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TEST=test/concurrency_control_test.rb`
Expected: FAIL — `test_configuration_defaults_to_enabled` with `NoMethodError: undefined method 'concurrency_control'`; the apply/key tests fail with "expected limits_concurrency to be called" / `NoMethodError` on `nil`.

- [ ] **Step 3: Add the config accessor**

In `lib/chrono_forge/configuration.rb`, after the `max_duration` accessor (line 25):

```ruby
    # When true (the default) and a workflow class responds to SolidQueue's
    # limits_concurrency, Executor.prepended automatically applies a
    # per-workflow-key concurrency limit (see executor.rb). Read at class-load
    # time: set this in the ChronoForge.configure initializer — flipping it
    # after workflow classes are loaded has no effect on them.
    attr_accessor :concurrency_control
```

And in `initialize` (line 27-31), add:

```ruby
      @concurrency_control = true
```

- [ ] **Step 4: Add the guard in Executor.prepended**

In `lib/chrono_forge/executor.rb`, at the top of `def self.prepended(base)` (line 42), before `base.class_attribute :default_retry_policy, ...`:

```ruby
      # SolidQueue efficiency layer: serialize same-workflow jobs at dispatch
      # time, so a concurrent wake-up blocks in the queue instead of burning a
      # worker slot only to be dropped by LockStrategy (ConcurrentExecutionError).
      # The semaphore key is "<Class>/<workflow key>": SolidQueue joins its
      # default concurrency group (self.class.name, instance_exec'd — correct
      # under subclassing) with this proc's result. to: 1 and on_conflict: :block
      # defaults are load-bearing (:discard would drop continuations and strand
      # workflows). duration strictly outlives the lock-steal threshold so the
      # semaphore never expires while ChronoForge still considers the lock live.
      # Inert off SolidQueue; a class's own limits_concurrency call after the
      # prepend overwrites this default.
      if ChronoForge.config.concurrency_control && base.respond_to?(:limits_concurrency)
        base.limits_concurrency(
          key: ->(key, **) { key },
          duration: ChronoForge.config.max_duration + 5.seconds
        )
      end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rake test TEST=test/concurrency_control_test.rb`
Expected: PASS — 5 tests, 0 failures.

- [ ] **Step 6: Full suite + lint**

Run: `bundle exec rake`
Expected: 312 tests (307 baseline + 5), 0 failures, 0 errors; standardrb reports no offenses. If standard flags style in the new files, run `bundle exec standardrb --fix` and re-run.

- [ ] **Step 7: Commit**

```bash
git add lib/chrono_forge/configuration.rb lib/chrono_forge/executor.rb test/concurrency_control_test.rb docs/superpowers/specs/2026-07-19-solid-queue-concurrency-design.md docs/superpowers/plans/
git commit -m "feat: auto-apply SolidQueue limits_concurrency per workflow key"
```

---

### Task 2: README documentation

**Goal:** README section documenting the automatic SolidQueue concurrency default, its rationale, and how to override or disable it.

**Files:**
- Modify: `README.md` (add a "SolidQueue" section; place it near other configuration/queue-related sections — read the README's table of contents first and match heading level and tone)

**Acceptance Criteria:**
- [ ] Section explains: automatic per-key limit, semaphore key shape `<Class>/<key>`, duration = `max_duration + 5.seconds` alignment rationale
- [ ] Warns explicitly against `on_conflict: :discard` (strands workflows)
- [ ] Shows per-class override (own `limits_concurrency` after the prepend) and global disable (`config.concurrency_control = false`)
- [ ] Notes config is read at class-load time (set in initializer)

**Verify:** `bundle exec rake` → suite + standard still pass (README-only change; sanity check nothing else drifted)

**Steps:**

- [ ] **Step 1: Add the README section**

Content to adapt to the README's established voice (headings/anchors to match its ToC conventions):

````markdown
## SolidQueue

When your app runs on SolidQueue, ChronoForge automatically applies a
per-workflow concurrency limit to every workflow class:

```ruby
# applied for you when ChronoForge::Executor is prepended:
limits_concurrency key: ->(key, **) { key },
  duration: ChronoForge.config.max_duration + 5.seconds
```

Concurrent jobs for the same workflow are serialized at dispatch time
(SolidQueue's semaphore key is `"YourWorkflow/<key>"` — the class name comes
from SolidQueue's default concurrency group), so duplicate wake-ups block in
the queue instead of occupying a worker slot only to be dropped by
ChronoForge's execution lock. The lock remains the correctness guarantee;
this is an efficiency layer.

The semaphore `duration` is derived from `max_duration` plus a small buffer so
it always outlives ChronoForge's lock-steal threshold — neither layer gives up
before the other. Both values are read when the workflow class is loaded, so
configure them in your initializer.

### Overriding

Declare your own `limits_concurrency` after the prepend to replace the
default — for example to throttle a class across all keys:

```ruby
class SyncWorkflow < ApplicationJob
  prepend ChronoForge::Executor

  limits_concurrency to: 3, key: "sync-api",
    duration: ChronoForge.config.max_duration + 5.seconds
end
```

Never use `on_conflict: :discard` with a ChronoForge workflow: workflows
resume via continuation jobs, and discarding a conflicting continuation
strands the workflow mid-flight.

To disable the automatic default entirely:

```ruby
ChronoForge.configure do |config|
  config.concurrency_control = false
end
```

On adapters without `limits_concurrency`, ChronoForge detects the API is
absent and applies nothing.
````

- [ ] **Step 2: Verify**

Run: `bundle exec rake`
Expected: 312 tests, 0 failures; standard clean.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document automatic SolidQueue concurrency control"
```
