# Composite Retry Policies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any retry site be configured with an ordered list of `RetryPolicy` objects so each error type gets its own independent attempt budget and backoff.

**Architecture:** A new pure `CompositeRetryPolicy` holds an ordered list of `RetryPolicy` objects and routes a failure to the first whose `retry_on` matches the live error (`is_a?`). The matched policy's index keys a `retry_counts` map — stored in execution/repetition log `metadata` for step sites, and threaded through the job args for the workflow-level site (mirroring the existing `attempt:` split). The single-policy path is unchanged and writes no `retry_counts`.

**Tech Stack:** Ruby, Rails (ActiveRecord/ActiveJob), Zeitwerk autoloading, Minitest + ChaoticJob.

**User Verification:** NO — no user verification required (internal API; correctness is covered by unit + integration tests).

---

### Task 1: `RetryPolicy` — `matches?`, `retry_backoff`, `compose`

**Goal:** Add the three pure additions to `RetryPolicy` without changing existing behavior.

**Files:**
- Modify: `lib/chrono_forge/executor/retry_policy.rb`
- Test: `test/retry_policy_test.rb`

**Acceptance Criteria:**
- [ ] `matches?(error)` returns the routing predicate (`nil` → any StandardError, `[]` → none, list → class/subclass)
- [ ] `retry_backoff(error, attempts:)` returns a `Duration` when retryable, `nil` otherwise, and ignores any block
- [ ] `RetryPolicy.compose(*policies)` returns a `CompositeRetryPolicy`
- [ ] All existing `RetryPolicyTest` tests still pass

**Verify:** `bin/rails test test/retry_policy_test.rb` → all pass (0 failures)

**Steps:**

- [ ] **Step 1: Write the failing tests**

Add to `test/retry_policy_test.rb`, before the final `end`:

```ruby
  # --- matches?: routing predicate ---

  def test_matches_nil_retry_on_matches_any_standard_error
    policy = RetryPolicy.new(retry_on: nil)
    assert policy.matches?(CustomError.new)
    assert policy.matches?(UnrelatedError.new)
  end

  def test_matches_empty_retry_on_matches_nothing
    policy = RetryPolicy.new(retry_on: [])
    refute policy.matches?(CustomError.new)
    refute policy.matches?(StandardError.new)
  end

  def test_matches_list_matches_class_and_subclass
    policy = RetryPolicy.new(retry_on: [CustomError])
    assert policy.matches?(CustomError.new)
    assert policy.matches?(SubError.new), "subclass matches"
    refute policy.matches?(UnrelatedError.new)
  end

  # --- retry_backoff: plain policy ignores the block ---

  def test_retry_backoff_returns_duration_when_retryable
    policy = RetryPolicy.new(max_attempts: 3, base: 1, cap: 1000, jitter: false)
    assert_in_delta 1.0, policy.retry_backoff(StandardError.new, attempts: 1).to_f, 0.001
  end

  def test_retry_backoff_returns_nil_past_cap
    policy = RetryPolicy.new(max_attempts: 2)
    assert_nil policy.retry_backoff(StandardError.new, attempts: 2)
  end

  def test_retry_backoff_ignores_block
    policy = RetryPolicy.new(max_attempts: 3, base: 1, cap: 1000, jitter: false)
    called = false
    result = policy.retry_backoff(StandardError.new, attempts: 1) { |_idx| called = true; 99 }
    refute called, "plain policy must not invoke the count block"
    assert_in_delta 1.0, result.to_f, 0.001
  end

  # --- compose factory ---

  def test_compose_builds_composite
    composite = RetryPolicy.compose(RetryPolicy.new, RetryPolicy.new)
    assert_instance_of ChronoForge::Executor::CompositeRetryPolicy, composite
    assert_equal 2, composite.policies.size
  end
```

- [ ] **Step 2: Run the tests, confirm they fail**

Run: `bin/rails test test/retry_policy_test.rb`
Expected: failures — `NoMethodError: undefined method 'matches?'` / `retry_backoff` / `compose`.

- [ ] **Step 3: Implement the additions**

In `lib/chrono_forge/executor/retry_policy.rb`, add a public `matches?` and `retry_backoff` after `backoff_for` (before `def self.step_default`), and the `compose` factory among the class methods:

```ruby
      # Public routing predicate: would this policy handle this error at all?
      # (independent of the attempt cap). nil retry_on = any StandardError;
      # [] = nothing; a list = those classes and their subclasses.
      def matches?(error)
        retryable_error?(error)
      end

      # Single-call decision used by every retry site: the backoff Duration to
      # retry, or nil to stop. A plain policy uses `attempts` and ignores any
      # block (the block exists only so a CompositeRetryPolicy can supply a
      # per-error count — see CompositeRetryPolicy#retry_backoff).
      def retry_backoff(error, attempts:)
        retryable?(error, attempts) ? backoff_for(attempts) : nil
      end
```

And add the factory next to the other `self.` methods:

```ruby
      # Build a composite policy from an ordered list of RetryPolicy objects.
      def self.compose(*policies)
        CompositeRetryPolicy.new(policies)
      end
```

- [ ] **Step 4: Run the tests, confirm green**

Run: `bin/rails test test/retry_policy_test.rb`
Expected: all pass (the `compose` test depends on Task 2's class — if running this task in isolation before Task 2, that one test errors; it passes once Task 2 lands. Keep both tasks in the same review batch, or temporarily skip `test_compose_builds_composite` until Task 2).

- [ ] **Step 5: Commit**

```bash
git add lib/chrono_forge/executor/retry_policy.rb test/retry_policy_test.rb
git commit -m "feat(retry): add RetryPolicy#matches?, #retry_backoff, and .compose"
```

```json:metadata
{"files": ["lib/chrono_forge/executor/retry_policy.rb", "test/retry_policy_test.rb"], "verifyCommand": "bin/rails test test/retry_policy_test.rb", "acceptanceCriteria": ["matches? routing predicate", "retry_backoff returns Duration/nil and ignores block", "compose returns CompositeRetryPolicy", "existing tests pass"], "requiresUserVerification": false}
```

---

### Task 2: `CompositeRetryPolicy` class

**Goal:** Add the pure `CompositeRetryPolicy` value object with routing, block-driven counting, and a coarse `max_attempts`.

**Files:**
- Create: `lib/chrono_forge/executor/composite_retry_policy.rb`
- Test: `test/composite_retry_policy_test.rb`

**Acceptance Criteria:**
- [ ] `policy_for(error)` returns the first matching sub-policy or `nil`
- [ ] `retry_backoff` routes on the live error, yields the matched policy's index, and uses the yielded count for the decision and backoff
- [ ] without a block, `retry_backoff` falls back to the passed `attempts`
- [ ] no match → `retry_backoff` returns `nil`
- [ ] `max_attempts` returns the coarsest bound, `nil` if any sub-policy is unbounded
- [ ] empty list raises `ArgumentError`

**Verify:** `bin/rails test test/composite_retry_policy_test.rb` → all pass

**Steps:**

- [ ] **Step 1: Write the failing test**

Create `test/composite_retry_policy_test.rb`:

```ruby
require "test_helper"

class CompositeRetryPolicyTest < ActiveSupport::TestCase
  RetryPolicy = ChronoForge::Executor::RetryPolicy
  CompositeRetryPolicy = ChronoForge::Executor::CompositeRetryPolicy

  class NetworkError < StandardError; end
  class FlakyNetworkError < NetworkError; end
  class RateLimitError < StandardError; end
  class DeclinedError < StandardError; end

  def composite
    CompositeRetryPolicy.new([
      RetryPolicy.new(retry_on: [NetworkError], max_attempts: 5, base: 1, cap: 1000, jitter: false),
      RetryPolicy.new(retry_on: [RateLimitError], max_attempts: 10, base: 2, cap: 1000, jitter: false),
      RetryPolicy.new(retry_on: [DeclinedError], max_attempts: 1)
    ])
  end

  def test_empty_policy_list_raises
    assert_raises(ArgumentError) { CompositeRetryPolicy.new([]) }
  end

  def test_policy_for_first_match_wins
    catch_all = RetryPolicy.new(retry_on: nil)
    c = CompositeRetryPolicy.new([RetryPolicy.new(retry_on: [NetworkError]), catch_all])
    assert_equal NetworkError, c.policy_for(NetworkError.new).retry_on.first
    assert_same catch_all, c.policy_for(RateLimitError.new), "falls through to catch-all"
  end

  def test_policy_for_subclass_routes_to_parent_policy
    assert_equal [NetworkError], composite.policy_for(FlakyNetworkError.new).retry_on
  end

  def test_policy_for_no_match_returns_nil
    assert_nil composite.policy_for(ArgumentError.new)
  end

  def test_retry_backoff_yields_matched_index_and_uses_count
    yielded = nil
    backoff = composite.retry_backoff(RateLimitError.new, attempts: 99) do |idx|
      yielded = idx
      3 # pretend this is the 3rd rate-limit failure
    end
    assert_equal 1, yielded, "RateLimitError is the 2nd policy (index 1)"
    # base 2, exponent (3-1)=2 -> 2 * 2**2 = 8
    assert_in_delta 8.0, backoff.to_f, 0.001, "backoff uses the yielded count, not attempts:"
  end

  def test_retry_backoff_without_block_uses_attempts
    backoff = composite.retry_backoff(NetworkError.new, attempts: 1)
    assert_in_delta 1.0, backoff.to_f, 0.001
  end

  def test_retry_backoff_stops_at_matched_policy_cap
    # DeclinedError policy max_attempts: 1 -> first failure (count 1) does not retry
    assert_nil composite.retry_backoff(DeclinedError.new, attempts: 1) { |_idx| 1 }
  end

  def test_retry_backoff_no_match_returns_nil
    assert_nil composite.retry_backoff(ArgumentError.new, attempts: 1) { |_idx| 1 }
  end

  def test_max_attempts_is_coarsest_bound
    assert_equal 10, composite.max_attempts
  end

  def test_max_attempts_nil_when_any_unbounded
    c = CompositeRetryPolicy.new([
      RetryPolicy.new(max_attempts: 3),
      RetryPolicy.new(max_attempts: nil)
    ])
    assert_nil c.max_attempts
  end
end
```

- [ ] **Step 2: Run the test, confirm it fails**

Run: `bin/rails test test/composite_retry_policy_test.rb`
Expected: `NameError: uninitialized constant ChronoForge::Executor::CompositeRetryPolicy`.

- [ ] **Step 3: Implement the class**

Create `lib/chrono_forge/executor/composite_retry_policy.rb`:

```ruby
module ChronoForge
  module Executor
    # An ordered list of RetryPolicy objects, each scoped to an error type via
    # its `retry_on`. On failure the first policy whose `retry_on` matches the
    # raised error (by `is_a?`) is applied, giving each error type its own
    # independent attempt budget and backoff curve. Put specific policies first
    # and a catch-all (`retry_on: nil`) last; an unmatched error is not retried.
    #
    # Pure: it never reads storage. The per-error count is supplied by the
    # caller through the block passed to #retry_backoff, keyed by the matched
    # policy's index.
    class CompositeRetryPolicy
      attr_reader :policies

      def initialize(policies)
        @policies = Array(policies)
        if @policies.empty?
          raise ArgumentError, "composite retry policy needs at least one policy"
        end
      end

      # First sub-policy whose retry_on matches the error, or nil.
      def policy_for(error)
        @policies.find { |p| p.matches?(error) }
      end

      # Routes on the live error and delegates the decision to the matched
      # sub-policy. When a block is given it is called with the matched policy's
      # index and must return that policy's running attempt count (1-based,
      # including the current failure); otherwise `attempts` is used.
      def retry_backoff(error, attempts:)
        index = @policies.index { |p| p.matches?(error) }
        return nil if index.nil?

        sub = @policies[index]
        count = block_given? ? yield(index) : attempts
        sub.retryable?(error, count) ? sub.backoff_for(count) : nil
      end

      # Coarsest attempt bound across sub-policies, for the workflow-level
      # safety-net guard. nil (unbounded) if any sub-policy is unbounded.
      def max_attempts
        caps = @policies.map(&:max_attempts)
        caps.include?(nil) ? nil : caps.max
      end
    end
  end
end
```

- [ ] **Step 4: Run the test, confirm green**

Run: `bin/rails test test/composite_retry_policy_test.rb test/retry_policy_test.rb`
Expected: all pass (this also makes Task 1's `test_compose_builds_composite` green).

- [ ] **Step 5: Commit**

```bash
git add lib/chrono_forge/executor/composite_retry_policy.rb test/composite_retry_policy_test.rb
git commit -m "feat(retry): add CompositeRetryPolicy value object"
```

```json:metadata
{"files": ["lib/chrono_forge/executor/composite_retry_policy.rb", "test/composite_retry_policy_test.rb"], "verifyCommand": "bin/rails test test/composite_retry_policy_test.rb", "acceptanceCriteria": ["policy_for first-match/subclass/nil", "retry_backoff yields index and uses count", "no-block falls back to attempts", "max_attempts coarse bound", "empty list raises"], "requiresUserVerification": false}
```

---

### Task 3: Executor coercion, class DSL overload, and `bump_retry_count!`

**Goal:** Accept arrays as composite policies everywhere, extend the class DSL to accept positional policies, and add the metadata counter helper used by step sites.

**Files:**
- Modify: `lib/chrono_forge/executor.rb`
- Test: `test/composite_retry_policy_executor_test.rb`

**Acceptance Criteria:**
- [ ] `coerce_policy` wraps an `Array` into a composite, passes a `RetryPolicy`/`CompositeRetryPolicy` through, and maps `nil` → `nil`
- [ ] `step_retry_policy` and `wait_retry_policy` coerce their override; `step_retry_policy` also coerces the class default
- [ ] `retry_policy(*policies)` with positional args stores a composite default; `retry_policy(**opts)` stays single; mixing raises `ArgumentError`
- [ ] `bump_retry_count!(log, idx)` increments the right slot, persists `metadata`, and returns the new count

**Verify:** `bin/rails test test/composite_retry_policy_executor_test.rb` → all pass

**Steps:**

- [ ] **Step 1: Write the failing test**

Create `test/composite_retry_policy_executor_test.rb`:

```ruby
require "test_helper"

# White-box tests for the executor's composite plumbing: policy coercion, the
# class-level DSL overload, and the metadata-backed per-error counter.
class CompositeRetryPolicyExecutorTest < ActiveSupport::TestCase
  RetryPolicy = ChronoForge::Executor::RetryPolicy
  CompositeRetryPolicy = ChronoForge::Executor::CompositeRetryPolicy

  # A bare object mixing in the executor so we can call its private helpers.
  def executor
    Class.new do
      prepend ChronoForge::Executor
    end.allocate
  end

  def test_coerce_policy_wraps_array
    coerced = executor.send(:coerce_policy, [RetryPolicy.new, RetryPolicy.new])
    assert_instance_of CompositeRetryPolicy, coerced
    assert_equal 2, coerced.policies.size
  end

  def test_coerce_policy_passes_through_single_and_composite
    single = RetryPolicy.new
    assert_same single, executor.send(:coerce_policy, single)
    composite = CompositeRetryPolicy.new([RetryPolicy.new])
    assert_same composite, executor.send(:coerce_policy, composite)
  end

  def test_coerce_policy_nil
    assert_nil executor.send(:coerce_policy, nil)
  end

  def test_class_dsl_positional_sets_composite_default
    klass = Class.new do
      prepend ChronoForge::Executor
      retry_policy RetryPolicy.new(retry_on: [ArgumentError]), RetryPolicy.new(retry_on: nil)
    end
    assert_instance_of CompositeRetryPolicy, klass.default_retry_policy
  end

  def test_class_dsl_kwargs_sets_single_default
    klass = Class.new do
      prepend ChronoForge::Executor
      retry_policy max_attempts: 7
    end
    assert_instance_of RetryPolicy, klass.default_retry_policy
    assert_equal 7, klass.default_retry_policy.max_attempts
  end

  def test_class_dsl_mixing_positional_and_kwargs_raises
    assert_raises(ArgumentError) do
      Class.new do
        prepend ChronoForge::Executor
        retry_policy RetryPolicy.new, max_attempts: 3
      end
    end
  end

  def test_bump_retry_count_increments_and_persists
    workflow = ChronoForge::Workflow.create!(job_class: "X", key: "bump-#{Time.now.to_i}-#{rand(10000)}")
    log = ChronoForge::ExecutionLog.create!(workflow: workflow, step_name: "s", metadata: {})

    assert_equal 1, executor.send(:bump_retry_count!, log, 0)
    assert_equal 2, executor.send(:bump_retry_count!, log, 0)
    assert_equal 1, executor.send(:bump_retry_count!, log, 1), "index 1 is independent"

    log.reload
    assert_equal({"0" => 2, "1" => 1}, log.metadata["retry_counts"])
  end

  def test_bump_retry_count_handles_nil_metadata
    workflow = ChronoForge::Workflow.create!(job_class: "X", key: "bumpnil-#{Time.now.to_i}-#{rand(10000)}")
    log = ChronoForge::ExecutionLog.create!(workflow: workflow, step_name: "s", metadata: nil)
    assert_equal 1, executor.send(:bump_retry_count!, log, 0)
  end
end
```

- [ ] **Step 2: Run the test, confirm it fails**

Run: `bin/rails test test/composite_retry_policy_executor_test.rb`
Expected: failures — `coerce_policy` / `bump_retry_count!` undefined, DSL doesn't accept positional args.

- [ ] **Step 3: Implement the executor changes**

In `lib/chrono_forge/executor.rb`, replace the class DSL `retry_policy` method (currently inside the `class << base` block):

```ruby
        # Class-level DSL to set this workflow's default retry policy. Applies to
        # workflow-level retries and to steps without a per-call override.
        # Positional RetryPolicy objects build a composite (per-error budgets);
        # keyword options build a single RetryPolicy. The two forms are mutually
        # exclusive.
        def retry_policy(*policies, **opts)
          if policies.any? && opts.any?
            raise ArgumentError, "retry_policy takes either positional policies or keyword options, not both"
          end

          self.default_retry_policy =
            policies.any? ? RetryPolicy.compose(*policies) : RetryPolicy.new(**opts)
        end
```

Update the resolver methods to coerce, and add `coerce_policy` + `bump_retry_count!` among the private methods:

```ruby
    def step_retry_policy(override)
      coerce_policy(override) || coerce_policy(self.class.default_retry_policy) || RetryPolicy.step_default
    end

    def wait_retry_policy(override)
      coerce_policy(override) || RetryPolicy.wait_default
    end
```

```ruby
    # Normalize a retry-policy value: an Array becomes a composite; a RetryPolicy
    # or CompositeRetryPolicy passes through; nil stays nil.
    def coerce_policy(value)
      value.is_a?(Array) ? RetryPolicy.compose(*value) : value
    end

    # JSON metadata key holding the per-error attempt counts of a composite
    # policy, keyed by the matched policy's index (as a string).
    RETRY_COUNTS_KEY = "retry_counts"

    # Increment the matched policy's slot in the log's retry-count map and return
    # the new count. Reassigns `metadata` so the JSON column is marked dirty.
    def bump_retry_count!(log, policy_index)
      meta = log.metadata || {}
      counts = meta[RETRY_COUNTS_KEY] || {}
      key = policy_index.to_s
      counts[key] = counts[key].to_i + 1
      meta[RETRY_COUNTS_KEY] = counts
      log.update!(metadata: meta)
      counts[key]
    end
```

Note: `workflow_retry_policy` does not need coercion — the class default is already coerced where it is set (the DSL stores a composite directly).

- [ ] **Step 4: Run the test, confirm green**

Run: `bin/rails test test/composite_retry_policy_executor_test.rb`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/chrono_forge/executor.rb test/composite_retry_policy_executor_test.rb
git commit -m "feat(retry): coerce array policies, composite class DSL, metadata counter"
```

```json:metadata
{"files": ["lib/chrono_forge/executor.rb", "test/composite_retry_policy_executor_test.rb"], "verifyCommand": "bin/rails test test/composite_retry_policy_executor_test.rb", "acceptanceCriteria": ["coerce_policy wraps array/passes through/nil", "resolvers coerce", "class DSL positional vs kwargs vs mixed", "bump_retry_count! increments+persists+nil-safe"], "requiresUserVerification": false}
```

---

### Task 4: Wire the three step sites to `retry_backoff`

**Goal:** Switch `durably_execute`, `wait_until`, and `durably_repeat` from the `retryable? … backoff_for` pair to a single `retry_backoff` call that supplies the per-error count via `bump_retry_count!`.

**Files:**
- Modify: `lib/chrono_forge/executor/methods/durably_execute.rb:104-110`
- Modify: `lib/chrono_forge/executor/methods/wait_until.rb:129-135`
- Modify: `lib/chrono_forge/executor/methods/durably_repeat.rb:229-233`

**Acceptance Criteria:**
- [ ] Each site computes `backoff` via `policy.retry_backoff(e, attempts: <log.attempts>) { |idx| bump_retry_count!(<log>, idx) }`
- [ ] Retry branch uses the returned `backoff`; the else branch is the unchanged terminal action
- [ ] Single-policy behavior is unchanged (block never runs) — existing integration tests still pass

**Verify:** `bin/rails test test/retry_policy_integration_test.rb` → all pass

**Steps:**

- [ ] **Step 1: Edit `durably_execute`**

In `lib/chrono_forge/executor/methods/durably_execute.rb`, replace the retry block (the `if policy.retryable?(e, execution_log.attempts)` … `else` head):

```ruby
            # Optional retry logic
            backoff = policy.retry_backoff(e, attempts: execution_log.attempts) do |idx|
              bump_retry_count!(execution_log, idx)
            end
            if backoff
              # Reschedule with the policy's backoff. The workflow replays on
              # resume and skips completed steps, so the rescheduled run picks
              # this step up again by its persisted execution log.
              self.class
                .set(wait: backoff)
                .perform_later(@workflow.key)

              # Halt current execution
              halt_execution!
            else
```

(The `else` body — marking the log failed and raising `ExecutionFailedError` — is unchanged.)

- [ ] **Step 2: Edit `wait_until`**

In `lib/chrono_forge/executor/methods/wait_until.rb`, replace the `if policy.retryable?(e, execution_log.attempts)` head:

```ruby
            backoff = policy.retry_backoff(e, attempts: execution_log.attempts) do |idx|
              bump_retry_count!(execution_log, idx)
            end
            if backoff
              # Reschedule with the policy's backoff
              self.class
                .set(wait: backoff)
                .perform_later(
                  @workflow.key
                )

              # Halt current execution
              halt_execution!
            else
```

(The `else` body is unchanged.)

- [ ] **Step 3: Edit `durably_repeat`**

In `lib/chrono_forge/executor/methods/durably_repeat.rb`, inside `execute_repetition_now`, replace the `if policy.retryable?(e, repetition_log.attempts)` head:

```ruby
          # Handle retry logic for this specific repetition
          backoff = policy.retry_backoff(e, attempts: repetition_log.attempts) do |idx|
            bump_retry_count!(repetition_log, idx)
          end
          if backoff
            # Reschedule this same repetition with the policy's backoff
            self.class
              .set(wait: backoff)
              .perform_later(@workflow.key)

            # Halt current execution
            halt_execution!
          else
```

(The `else` body — marking failed and applying `on_error` — is unchanged.)

- [ ] **Step 4: Run the existing integration + unit suites, confirm green**

Run: `bin/rails test test/retry_policy_integration_test.rb test/workflow_retry_api_test.rb`
Expected: all pass — single-policy behavior is byte-for-byte unchanged.

- [ ] **Step 5: Commit**

```bash
git add lib/chrono_forge/executor/methods/durably_execute.rb lib/chrono_forge/executor/methods/wait_until.rb lib/chrono_forge/executor/methods/durably_repeat.rb
git commit -m "feat(retry): route step sites through retry_backoff with per-error counts"
```

```json:metadata
{"files": ["lib/chrono_forge/executor/methods/durably_execute.rb", "lib/chrono_forge/executor/methods/wait_until.rb", "lib/chrono_forge/executor/methods/durably_repeat.rb"], "verifyCommand": "bin/rails test test/retry_policy_integration_test.rb test/workflow_retry_api_test.rb", "acceptanceCriteria": ["each step site uses retry_backoff + bump_retry_count!", "terminal branches unchanged", "single-policy integration tests pass"], "requiresUserVerification": false}
```

---

### Task 5: Wire the workflow-level `perform` site

**Goal:** Give workflow-level (uncaught) retries per-error budgets by threading a `retry_counts` map through the job args, and keep the early safety-net guard correct for composites.

**Files:**
- Modify: `lib/chrono_forge/executor.rb` (`perform` signature + rescue block, ~lines 64-126)

**Acceptance Criteria:**
- [ ] `perform` accepts `retry_counts: {}` and threads it through the retry reschedule alongside `attempt:`
- [ ] The rescue uses `policy.retry_backoff(e, attempts: attempts_made) { |idx| <increment retry_counts[idx]> }`
- [ ] The early guard `attempt >= policy.max_attempts` still works (composite returns a coarse `max_attempts`)
- [ ] Existing workflow-level retry tests pass

**Verify:** `bin/rails test test/workflow_retry_api_test.rb test/retry_policy_integration_test.rb` → all pass

**Steps:**

- [ ] **Step 1: Add `retry_counts` to the signature**

In `lib/chrono_forge/executor.rb`, change:

```ruby
    def perform(key, attempt: 0, retry_workflow: false, options: {}, **kwargs)
```

to:

```ruby
    def perform(key, attempt: 0, retry_counts: {}, retry_workflow: false, options: {}, **kwargs)
```

- [ ] **Step 2: Use `retry_backoff` in the rescue**

Replace the workflow-level retry decision (currently `if policy.retryable?(e, attempts_made)` … through the `perform_later(... attempt: attempts_made)`):

```ruby
        # Retry if applicable. `attempt` is a 0-based index, so the count of
        # attempts made so far (including this one) is attempt + 1.
        attempts_made = attempt + 1
        backoff = policy.retry_backoff(e, attempts: attempts_made) do |idx|
          key_s = idx.to_s
          retry_counts[key_s] = retry_counts[key_s].to_i + 1
          retry_counts[key_s]
        end
        if backoff
          self.class
            .set(wait: backoff)
            .perform_later(workflow.key, attempt: attempts_made, retry_counts: retry_counts)
        else
          fail_workflow! error_log
        end
```

The early safety-net guard at the top of `perform` is unchanged:

```ruby
      policy = workflow_retry_policy
      if policy.max_attempts && attempt >= policy.max_attempts
        Rails.logger.error { "ChronoForge:#{self.class} max attempts reached for job workflow(#{key})" }
        return
      end
```

`CompositeRetryPolicy#max_attempts` (Task 2) returns the coarsest bound, so this guard remains a safe over-estimate and never trips a composite prematurely.

- [ ] **Step 3: Run the workflow-level suites, confirm green**

Run: `bin/rails test test/workflow_retry_api_test.rb test/retry_policy_integration_test.rb`
Expected: all pass — single-policy workflow retries thread an empty `retry_counts` and behave exactly as before.

- [ ] **Step 4: Commit**

```bash
git add lib/chrono_forge/executor.rb
git commit -m "feat(retry): per-error budgets for workflow-level retries via job args"
```

```json:metadata
{"files": ["lib/chrono_forge/executor.rb"], "verifyCommand": "bin/rails test test/workflow_retry_api_test.rb test/retry_policy_integration_test.rb", "acceptanceCriteria": ["perform threads retry_counts", "rescue uses retry_backoff", "safety-net guard honors coarse max_attempts", "single-policy workflow tests pass"], "requiresUserVerification": false}
```

---

### Task 6: Integration tests for composite behavior

**Goal:** Prove per-error budgets, per-error backoff, fail-fast, subclass routing, array coercion, and the single-policy regression — end to end through the executor.

**Files:**
- Create: `test/composite_retry_policy_integration_test.rb`

**Acceptance Criteria:**
- [ ] Different error types accumulate independent budgets at one step
- [ ] A `max_attempts: 1` sub-policy fails fast
- [ ] A subclass of a `retry_on` class draws from the parent policy's budget
- [ ] An array passed to `retry_policy:` is honored (coerced to composite)
- [ ] A single policy still writes no `retry_counts`

**Verify:** `bin/rails test test/composite_retry_policy_integration_test.rb` → all pass

**Steps:**

- [ ] **Step 1: Write the integration tests**

Create `test/composite_retry_policy_integration_test.rb`:

```ruby
require "test_helper"

# End-to-end: composite retry_policy arrays wired through the executor.
class CompositeRetryPolicyIntegrationTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  RetryPolicy = ChronoForge::Executor::RetryPolicy

  class NetworkError < StandardError; end
  class FlakyNetworkError < NetworkError; end
  class DeclinedError < StandardError; end

  def define_workflow(name, &block)
    test_class_name = "#{name}#{Time.now.to_i}_#{rand(100000)}"
    Object.const_set(test_class_name, Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      class_eval(&block)
    end)
    Object.const_get(test_class_name)
  end

  def test_each_error_type_has_an_independent_budget
    key = "composite_budgets_#{Time.now.to_i}_#{rand(10000)}"
    klass = define_workflow("CompositeBudgets") do
      define_method(:perform) do
        durably_execute :flaky, retry_policy: [
          RetryPolicy.new(retry_on: [NetworkError], max_attempts: 3, base: 0, cap: 0, jitter: false),
          RetryPolicy.new(retry_on: [DeclinedError], max_attempts: 1)
        ]
      end
      # Fails with NetworkError until its budget (3) is spent, then would
      # raise DeclinedError — which fails fast at max_attempts: 1.
      define_method(:flaky) do
        n = (context[:n] = (context[:n] || 0) + 1)
        raise NetworkError, "net #{n}" if n < 3
        raise DeclinedError, "declined"
      end
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "durably_execute$flaky")
    # 3 NetworkError attempts (budget 3) + 1 DeclinedError attempt (budget 1) = 4
    assert_equal 4, log.attempts
    assert_equal "failed", log.state
    assert_equal({"0" => 3, "1" => 1}, log.metadata["retry_counts"])
  end

  def test_subclass_draws_from_parent_policy_budget
    key = "composite_subclass_#{Time.now.to_i}_#{rand(10000)}"
    klass = define_workflow("CompositeSubclass") do
      define_method(:perform) do
        durably_execute :always_flaky, retry_policy: [
          RetryPolicy.new(retry_on: [NetworkError], max_attempts: 2, base: 0, cap: 0, jitter: false)
        ]
      end
      define_method(:always_flaky) { raise FlakyNetworkError, "boom" }
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "durably_execute$always_flaky")
    assert_equal 2, log.attempts, "subclass routes to NetworkError policy (budget 2)"
    assert_equal({"0" => 2}, log.metadata["retry_counts"])
  end

  def test_unmatched_error_fails_fast
    key = "composite_unmatched_#{Time.now.to_i}_#{rand(10000)}"
    klass = define_workflow("CompositeUnmatched") do
      define_method(:perform) do
        durably_execute :raises_arg, retry_policy: [
          RetryPolicy.new(retry_on: [NetworkError], max_attempts: 5)
        ]
      end
      define_method(:raises_arg) { raise ArgumentError, "nope" }
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "durably_execute$raises_arg")
    assert_equal 1, log.attempts, "no matching policy -> fail fast"
    assert_equal "failed", log.state
  end

  def test_single_policy_writes_no_retry_counts
    key = "single_no_counts_#{Time.now.to_i}_#{rand(10000)}"
    klass = define_workflow("SingleNoCounts") do
      define_method(:perform) do
        durably_execute :always_fails,
          retry_policy: RetryPolicy.new(max_attempts: 2, base: 0, cap: 0, jitter: false)
      end
      define_method(:always_fails) { raise "boom" }
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "durably_execute$always_fails")
    assert_equal 2, log.attempts
    assert_nil log.metadata["retry_counts"], "single policy path writes no retry_counts"
  end
end
```

- [ ] **Step 2: Run the test, confirm green**

Run: `bin/rails test test/composite_retry_policy_integration_test.rb`
Expected: all pass.

- [ ] **Step 3: Run the full suite**

Run: `bin/rails test`
Expected: all pass — no regressions across the whole suite.

- [ ] **Step 4: Commit**

```bash
git add test/composite_retry_policy_integration_test.rb
git commit -m "test(retry): integration coverage for composite retry policies"
```

```json:metadata
{"files": ["test/composite_retry_policy_integration_test.rb"], "verifyCommand": "bin/rails test", "acceptanceCriteria": ["independent per-error budgets", "fail-fast max_attempts:1", "subclass routes to parent budget", "array coerced", "single policy writes no retry_counts", "full suite green"], "requiresUserVerification": false}
```

---

### Task 7: Document composite policies in the README

**Goal:** Add a "Composite retry policies" subsection to the existing Retry Policies docs, including the ordering footgun and the per-error-budget semantics.

**Files:**
- Modify: `README.md` (Retry Policies section, ~line 214-252)

**Acceptance Criteria:**
- [ ] A worked composite example (`retry_policy: [ ... ]`) with `retry_on` per policy
- [ ] States: first match wins; catch-all (`retry_on: nil`) last; unmatched → fail fast
- [ ] States: each error type has an independent budget and its own backoff
- [ ] Notes the class-level DSL accepts positional policies for a composite default

**Verify:** `grep -n "Composite" README.md` → shows the new subsection heading

**Steps:**

- [ ] **Step 1: Add the subsection**

In `README.md`, after the existing per-call/class-default retry examples (just before the section that documents `wait_until`'s opt-in, around line 252), insert:

````markdown
#### Composite policies (per-error budgets)

Pass an **array** of policies to handle different error types differently. On a
failure, the **first** policy whose `retry_on` matches the raised error applies —
each error type gets its **own independent attempt budget and backoff**:

```ruby
durably_execute :charge_card, retry_policy: [
  RetryPolicy.new(retry_on: [NetworkError],         max_attempts: 5),            # transient: retry hard
  RetryPolicy.new(retry_on: [RateLimitError],       max_attempts: 10, base: 5),  # back off longer
  RetryPolicy.new(retry_on: [PaymentDeclinedError], max_attempts: 1),            # fail fast, never retry
  RetryPolicy.new(retry_on: nil)                                                 # catch-all (optional), keep last
]
```

- **Order matters** — the first matching policy wins, so list specific errors
  first and a catch-all (`retry_on: nil`) last. An error matched by no policy is
  **not retried** (fails fast).
- A subclass of a listed error routes to that policy and draws from its budget.
- The class-level DSL accepts the same form as positional arguments:

  ```ruby
  retry_policy RetryPolicy.new(retry_on: [NetworkError], max_attempts: 5),
               RetryPolicy.new(retry_on: nil, max_attempts: 2)
  ```
````

- [ ] **Step 2: Verify the heading exists**

Run: `grep -n "Composite policies" README.md`
Expected: one match.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(retry): document composite per-error retry policies"
```

```json:metadata
{"files": ["README.md"], "verifyCommand": "grep -n 'Composite policies' README.md", "acceptanceCriteria": ["worked array example", "ordering + catch-all + fail-fast stated", "independent budget/backoff stated", "class DSL positional form shown"], "requiresUserVerification": false}
```

---

## Self-Review

**Spec coverage:**
- `matches?`, `retry_backoff`, `compose` → Task 1 ✓
- `CompositeRetryPolicy` (routing, block-count, `max_attempts`, empty guard) → Task 2 ✓
- `coerce_policy`, class DSL overload, `bump_retry_count!` → Task 3 ✓
- Step-site wiring (metadata counter) → Task 4 ✓
- Workflow-level wiring (job-arg counter, safety net) → Task 5 ✓
- Integration: per-error budgets, fail-fast, subclass, array coercion, single-policy regression → Task 6 ✓
- Ordering/reorder docs → Task 7 ✓ (reorder caveat is a documented edge in the spec; README covers ordering)

**Placeholder scan:** none — every code/step is concrete.

**Type consistency:** `retry_backoff(error, attempts:)`, `matches?(error)`, `policy_for(error)`, `RetryPolicy.compose`, `CompositeRetryPolicy.new(policies)`, `coerce_policy`, `bump_retry_count!(log, idx)`, `RETRY_COUNTS_KEY = "retry_counts"`, `retry_counts:` job arg — consistent across all tasks.

**Verification requirement scan:** The spec/prompt requires NO user verification (internal API, test-covered). No verification task needed.
