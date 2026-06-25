# Reserved-keyword Guard + Keywords-only Enqueue Contract — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the public `perform_now`/`perform_later` of `Executor`-prepended jobs reject ChronoForge's reserved internal kwargs and any extra positional argument, while keeping `options`/user kwargs and the `retry_now`/`retry_later` helpers working.

**Architecture:** All changes live in `lib/chrono_forge/executor.rb` inside the `class << base` block (plus one module-level constant). A shared private `__validate_enqueue!` guard backs both public enqueue methods. `retry_now`/`retry_later` are rewritten to enqueue through `.set(...)`, whose ActiveJob `ConfiguredJob` proxy bypasses the class-level override, letting the framework inject the reserved `retry_workflow: true` flag past the guard. Framework continuations already use `.set(...)` and need no change.

**Tech Stack:** Ruby, Rails/ActiveJob 7.1.3.4, Minitest (`ActiveJob::TestCase`), ChaoticJob test helpers, Combustion test harness.

**User Verification:** NO — no user verification required.

---

## File Structure

- **Modify** `lib/chrono_forge/executor.rb`
  - Add module-level constant `RESERVED_KWARGS` near `STEP_NAME_DELIMITER` (line 19).
  - Replace the `perform_now`, `perform_later`, `retry_now`, `retry_later` definitions in the `class << base` block (lines ~29–54). Leave `retry_policy` (lines ~56–68) untouched.
  - Append a `private` section with `__validate_enqueue!` at the **end** of the `class << base` block (after `retry_policy`) so `retry_policy` stays public.
- **Create** `test/enqueue_contract_test.rb` — covers reserved-key rejection, keywords-only contract, non-string key, `options`/kwargs pass-through, and retry-helper reserved-key rejection.

---

### Task 1: Reserved-key + keywords-only enqueue guard, with retry-helper rerouting

**Goal:** Public `perform_now`/`perform_later` reject `attempt`/`retry_counts`/`retry_workflow` and extra positionals; `options` and user kwargs still flow through; `retry_now`/`retry_later` keep working by routing past the guard.

**Files:**
- Modify: `lib/chrono_forge/executor.rb` (constant near line 19; `class << base` block lines ~29–54; append private helper before the block's closing `end` at line ~69)
- Test: `test/enqueue_contract_test.rb` (create)

**Acceptance Criteria:**
- [ ] `perform_later`/`perform_now` raise `ArgumentError` (message names the key, contains "reserved") when passed `attempt:`, `retry_counts:`, or `retry_workflow:`, and enqueue nothing.
- [ ] `perform_later`/`perform_now` raise `ArgumentError` (message mentions "keyword") when given a second positional argument.
- [ ] Non-String `key` still raises `ArgumentError`.
- [ ] `perform_later(key, foo:, options:)` enqueues; `options` reaches `workflow.options` and user kwargs reach `workflow.kwargs`/the job body.
- [ ] `retry_now`/`retry_later` reject reserved keys supplied by the caller, and the existing retry end-to-end tests still pass.
- [ ] Full suite green: `bundle exec rake test`.

**Verify:** `bundle exec rake test TEST=test/enqueue_contract_test.rb` → all pass, then `bundle exec rake test` → 139+ tests, 0 failures, 0 errors.

**Steps:**

- [ ] **Step 1: Write the failing tests**

Create `test/enqueue_contract_test.rb`:

```ruby
require "test_helper"

# Public enqueue contract for Executor-prepended jobs: perform_now/perform_later
# accept exactly one positional (`key`) plus keywords, reject ChronoForge's
# reserved internal kwargs, and pass `options`/user kwargs through to the
# workflow record. retry_now/retry_later route past the guard via `.set(...)`.
class EnqueueContractTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  RESERVED = %i[attempt retry_counts retry_workflow].freeze

  def setup
    ChronoForge::Workflow.destroy_all
  end

  class ContractJob < WorkflowJob
    prepend ChronoForge::Executor
    def perform(foo: nil)
      context[:foo] = foo
    end
  end

  # --- reserved-key rejection ------------------------------------------------

  def test_perform_later_rejects_reserved_keys
    RESERVED.each do |reserved|
      err = assert_raises(ArgumentError) do
        assert_no_enqueued_jobs do
          ContractJob.perform_later("k-#{reserved}", reserved => 1)
        end
      end
      assert_match(/reserved/, err.message)
      assert_match(reserved.to_s, err.message)
    end
  end

  def test_perform_now_rejects_reserved_keys
    RESERVED.each do |reserved|
      err = assert_raises(ArgumentError) do
        ContractJob.perform_now("k-#{reserved}", reserved => 1)
      end
      assert_match(/reserved/, err.message)
    end
  end

  # --- keywords-only contract ------------------------------------------------

  def test_perform_later_rejects_extra_positional
    err = assert_raises(ArgumentError) do
      assert_no_enqueued_jobs { ContractJob.perform_later("k", 99) }
    end
    assert_match(/keyword/, err.message)
  end

  def test_perform_now_rejects_extra_positional
    err = assert_raises(ArgumentError) { ContractJob.perform_now("k", 99) }
    assert_match(/keyword/, err.message)
  end

  def test_non_string_key_still_rejected
    assert_raises(ArgumentError) { ContractJob.perform_later(123) }
    assert_raises(ArgumentError) { ContractJob.perform_now(123) }
  end

  # --- public kwargs pass through --------------------------------------------

  def test_options_and_user_kwargs_pass_through
    key = "contract-#{SecureRandom.hex(4)}"
    ContractJob.perform_later(key, foo: "bar", options: {plan: "pro"})
    perform_all_jobs

    wf = ChronoForge::Workflow.find_by(key: key)
    assert_equal({"plan" => "pro"}, wf.options)
    assert_equal "bar", wf.kwargs["foo"]
    assert_equal "bar", wf.context["foo"]
  end

  # --- retry helpers route past the guard ------------------------------------

  def test_retry_helpers_reject_reserved_keys_from_caller
    assert_raises(ArgumentError) { ContractJob.retry_now("k", attempt: 1) }
    assert_raises(ArgumentError) { ContractJob.retry_later("k", attempt: 1) }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rake test TEST=test/enqueue_contract_test.rb`
Expected: FAIL — reserved-key/positional rejection tests fail because the current guard only checks `key.is_a?(String)` (reserved kwargs are silently swallowed; a second positional raises Ruby's generic arity error, not our message — so the `/keyword/` match fails).

- [ ] **Step 3: Add the `RESERVED_KWARGS` constant**

In `lib/chrono_forge/executor.rb`, after the `STEP_NAME_DELIMITER` definition (line 19), add:

```ruby
    # Keyword args ChronoForge threads through job args internally. Users must
    # not pass these to perform_now/perform_later; the framework injects them
    # via `.set(...)` continuations, whose ConfiguredJob proxy bypasses the
    # class-level guard in `prepended` below.
    RESERVED_KWARGS = %i[attempt retry_counts retry_workflow].freeze
```

- [ ] **Step 4: Rewrite the enqueue/retry methods**

In the `class << base` block, replace the existing `perform_now`, `perform_later`, `retry_now`, and `retry_later` definitions (lines ~29–54) with:

```ruby
        # Public enqueue contract: exactly one positional (`key`) plus keywords.
        # Reserved internal kwargs (RESERVED_KWARGS) are rejected here; the
        # framework injects them only via `.set(...)` continuations, whose
        # ActiveJob ConfiguredJob proxy bypasses these class-level overrides.
        def perform_now(key, *extra, **kwargs)
          __validate_enqueue!(key, extra, kwargs)
          super(key, **kwargs)
        end

        def perform_later(key, *extra, **kwargs)
          __validate_enqueue!(key, extra, kwargs)
          super(key, **kwargs)
        end

        # Re-run a failed/stalled workflow. Routes through `.set(...)` so the
        # reserved `retry_workflow: true` flag reaches the instance perform
        # without tripping the public guard above.
        def retry_now(key, **kwargs)
          __validate_enqueue!(key, [], kwargs)
          set.perform_now(key, retry_workflow: true, **kwargs)
        end

        def retry_later(key, **kwargs)
          __validate_enqueue!(key, [], kwargs)
          set.perform_later(key, retry_workflow: true, **kwargs)
        end
```

Leave the `retry_policy` method that follows **unchanged**.

- [ ] **Step 5: Append the private guard at the end of the `class << base` block**

Immediately before the `end` that closes `class << base` (after `retry_policy`, line ~69), add:

```ruby

        private

        def __validate_enqueue!(key, extra, kwargs)
          unless key.is_a?(String)
            raise ArgumentError, "Workflow key must be a string as the first argument"
          end
          unless extra.empty?
            raise ArgumentError,
              "ChronoForge workflows accept only `key` positionally; pass " \
              "everything else as keywords (got #{extra.size} extra positional arg(s))"
          end
          reserved = kwargs.keys & RESERVED_KWARGS
          if reserved.any?
            raise ArgumentError,
              "#{reserved.join(", ")} #{reserved.one? ? "is a reserved" : "are reserved"} " \
              "ChronoForge keyword(s) and cannot be passed to perform_now/perform_later"
          end
        end
```

- [ ] **Step 6: Run the new tests to verify they pass**

Run: `bundle exec rake test TEST=test/enqueue_contract_test.rb`
Expected: PASS (all tests).

- [ ] **Step 7: Run the full suite (regression — confirms retry rewrite is safe)**

Run: `bundle exec rake test`
Expected: PASS — 139 prior tests + new file, 0 failures, 0 errors. This is the safety net for the `retry_now`/`retry_later` rewrite (existing retry e2e tests in `test/workflow_retry_api_test.rb` and `test/chrono_forge_test.rb` exercise the happy path).

- [ ] **Step 8: Commit**

```bash
git add lib/chrono_forge/executor.rb test/enqueue_contract_test.rb docs/superpowers/specs/2026-06-25-reserved-kwarg-guard-design.md docs/superpowers/plans/2026-06-25-reserved-kwarg-guard.md
git commit -m "feat(executor): guard reserved kwargs and enforce keywords-only enqueue"
```

```json:metadata
{"files": ["lib/chrono_forge/executor.rb", "test/enqueue_contract_test.rb"], "verifyCommand": "bundle exec rake test", "acceptanceCriteria": ["perform_now/perform_later reject attempt/retry_counts/retry_workflow with a clear ArgumentError and enqueue nothing", "extra positional args rejected with a keywords-only message", "non-string key still rejected", "options and user kwargs pass through to the workflow record", "retry_now/retry_later reject caller-supplied reserved keys and existing retry e2e tests still pass", "full suite green"], "requiresUserVerification": false}
```

---

## Notes / Out of Scope

- `wait_condition` (internal kwarg in `wait_until`) is intentionally **not** added to `RESERVED_KWARGS`: it only travels via `.set(...)` and never reaches the guard.
- `ChronoForge::CleanupJob` is a plain `ActiveJob::Base` (does not prepend `Executor`); the guard does not apply to it.
- The gemspec leaves `activerecord` unpinned; a fresh `bundle install` can resolve to Rails 8.1 and conflict with `sqlite3 ~> 1.4`. Unrelated to this change — keep the worktree on main's known-good `Gemfile.lock` (Rails 7.1.3.4).
