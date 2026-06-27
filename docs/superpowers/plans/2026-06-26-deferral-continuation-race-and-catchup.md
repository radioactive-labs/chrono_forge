# Deferral Continuation Race & Catch-up Surge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the continuation/lock-release race (Issue 1) by publishing every continuation only after the lock is released, and collapse `durably_repeat` catch-up from O(missed intervals) to O(1) with a closed-form fast-forward of the expired prefix (Issue 2).

**Architecture:** (1) Deferral primitives stop calling `perform_later` inline; they record an intended continuation on the instance, and the executor flushes it in `ensure` *after* `release_lock`. (2) `durably_repeat` computes the first non-expired grid tick in closed form, advances the coordination log's `last_execution_at`, and writes a single summary `ExecutionLog` for the skipped prefix instead of one timed-out row per tick.

**Tech Stack:** Ruby 3.2, Rails (ActiveJob/ActiveRecord), Minitest + `chaotic_job`, SolidQueue (prod). Gem: `chrono_forge` 0.9.1.

**Spec:** `docs/superpowers/specs/2026-06-26-deferral-continuation-race-and-catchup-design.md`

**User Verification:** NO — no user verification required (automated tests are the acceptance gate).

**Test command (single file):** `bundle exec ruby -Itest test/<file>_test.rb`
**Full suite:** `bundle exec rake test`

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `lib/chrono_forge/executor.rb` | Continuation recording + post-release flush | Add `enqueue_continuation` / `flush_continuation!`; flush in `ensure`; convert workflow-retry enqueue | 
| `lib/chrono_forge/executor/methods/wait.rb` | `wait` reschedule | Convert inline enqueue → `enqueue_continuation` |
| `lib/chrono_forge/executor/methods/wait_until.rb` | poll + cond-error retry | Convert 2 inline enqueues |
| `lib/chrono_forge/executor/methods/durably_execute.rb` | retry backoff | Convert 1 inline enqueue |
| `lib/chrono_forge/executor/methods/durably_repeat.rb` | schedule-later, repetition-retry, schedule-next, **fast-forward** | Convert 3 inline enqueues (Task 1); add `fast_forward_expired_prefix` (Task 2) |
| `test/continuation_flush_test.rb` | Issue 1 tests | Create (Task 1) |
| `test/durably_repeat_test.rb` | Issue 2 tests + updates | Add fast-forward tests; update 2 timeout tests (Task 2) |

---

### Task 1: Defer all continuation enqueues until after lock release

**Goal:** No continuation job is published while the enqueuing job still holds the workflow lock; all 8 enqueue sites route through one recorded slot flushed in `ensure` after `release_lock`.

**Files:**
- Modify: `lib/chrono_forge/executor.rb` (add helpers near `halt_execution!` ~`:305`; flush in `ensure` `:168-173`; convert workflow-retry enqueue `:162-164`)
- Modify: `lib/chrono_forge/executor/methods/wait.rb:106-108`
- Modify: `lib/chrono_forge/executor/methods/wait_until.rb:134-138` and `:180-185`
- Modify: `lib/chrono_forge/executor/methods/durably_execute.rb:111-113`
- Modify: `lib/chrono_forge/executor/methods/durably_repeat.rb:192-194`, `:234-236`, `:287-289`
- Test: `test/continuation_flush_test.rb` (create)

**Acceptance Criteria:**
- [ ] Every continuation observes the workflow lock already released (`locked_by == nil`) at enqueue time.
- [ ] Per-site kwargs are preserved (`wait_condition:` for the `wait_until` poll; `attempt:`/`retry_counts:` for the workflow retry).
- [ ] `flush_continuation!` is a no-op when no continuation was recorded, and is skipped when `release_lock` raises (overrun loses the lock).
- [ ] Full suite still green (regression guard for retry/attempt threading).

**Verify:** `bundle exec ruby -Itest test/continuation_flush_test.rb` → all pass; then `bundle exec rake test` → green.

**Steps:**

- [ ] **Step 1: Write the failing tests**

Create `test/continuation_flush_test.rb`:

```ruby
require "test_helper"

class ContinuationFlushTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  # The core ordering guarantee: a continuation must only become claimable after
  # the enqueuing job has released the lock. We observe the workflow's lock owner
  # in the DB at the instant each same-key continuation is enqueued; it must be nil.
  def test_continuation_is_enqueued_only_after_lock_released
    key = "flush_order_#{Time.now.to_i}_#{rand(10_000)}"

    locked_owners = []
    subscriber = ActiveSupport::Notifications.subscribe("enqueue.active_job") do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      job = event.payload[:job]
      next unless job.arguments.first == key
      wf = ChronoForge::Workflow.find_by(key: key)
      locked_owners << (wf && wf.locked_by)
    end

    begin
      WaitContinuationJob.perform_later(key)
      perform_all_jobs_before(1.second)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # At least one continuation enqueue must have been observed from inside the job.
    refute locked_owners.empty?, "expected to observe a continuation enqueue"
    assert locked_owners.all?(&:nil?),
      "continuation must be enqueued only after lock release; observed owners: #{locked_owners.inspect}"
  end

  # flush_continuation! must round-trip arbitrary kwargs into the continuation.
  def test_flush_continuation_preserves_kwargs
    key = "flush_kwargs_#{Time.now.to_i}_#{rand(10_000)}"
    workflow = ChronoForge::Workflow.create!(
      key: key, job_class: "KitchenSink", kwargs: {}, options: {}, context: {}, state: :idle
    )

    job = KitchenSink.new
    job.instance_variable_set(:@workflow, workflow)
    job.send(:enqueue_continuation, wait: 0.seconds, wait_condition: "my_cond")

    assert_difference -> { enqueued_jobs.size }, 1 do
      job.send(:flush_continuation!)
    end

    last = enqueued_jobs.last
    assert_includes last.to_s, key, "continuation should target the workflow key"
    assert_includes last.to_s, "my_cond", "continuation must carry the wait_condition kwarg"
  end

  # No recorded continuation => flush does nothing.
  def test_flush_continuation_is_noop_without_recorded_continuation
    job = KitchenSink.new
    assert_no_difference -> { enqueued_jobs.size } do
      job.send(:flush_continuation!)
    end
  end
end

class WaitContinuationJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    # First pass: wait period not elapsed -> records a continuation and halts.
    wait 1.hour, "long_wait"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Itest test/continuation_flush_test.rb`
Expected: FAIL —
- `test_continuation_is_enqueued_only_after_lock_released`: observed owner is the job id (non-nil), because `wait` enqueues before the `ensure` release.
- `test_flush_continuation_preserves_kwargs` / `..._noop_...`: `NoMethodError: undefined method 'enqueue_continuation'/'flush_continuation!'`.

- [ ] **Step 3: Add the recording + flush helpers in the executor**

In `lib/chrono_forge/executor.rb`, add near `halt_execution!` (private section, ~`:305`):

```ruby
    # Record the continuation this job intends to enqueue. It is NOT published
    # here: publishing while the lock is still held lets another worker claim it
    # and lose the lock-acquisition race. The executor flushes it in `ensure`,
    # after release_lock (see #flush_continuation!). At most one continuation is
    # recorded per job run (every primitive records one then halts, or falls
    # through the workflow-retry rescue).
    def enqueue_continuation(wait:, **kwargs)
      @continuation = {wait: wait, kwargs: kwargs}
    end

    # Publish the recorded continuation, if any. Called from `ensure` only after
    # the lock row has been updated to released, so even a zero-delay continuation
    # finds the lock free.
    def flush_continuation!
      return unless @continuation

      self.class
        .set(wait: @continuation[:wait])
        .perform_later(@workflow.key, **@continuation[:kwargs])
    end
```

- [ ] **Step 4: Flush in `ensure`, after release_lock**

In `lib/chrono_forge/executor.rb`, change the `ensure` block (`:168-173`) from:

```ruby
      ensure
        if lock_acquired # Only release lock if we acquired it
          context.save!
          self.class::LockStrategy.release_lock(job_id, workflow)
        end
      end
```

to:

```ruby
      ensure
        if lock_acquired # Only release lock if we acquired it
          context.save!
          self.class::LockStrategy.release_lock(job_id, workflow)
          # Publish the continuation only now — after the lock is released — so a
          # zero-delay, same-key continuation can't lose the acquire race against
          # this still-locked job. If release_lock raised (this job overran and
          # lost the lock), we never reach here and another job owns continuation.
          flush_continuation!
        end
      end
```

- [ ] **Step 5: Convert the workflow-level retry enqueue**

In `lib/chrono_forge/executor.rb`, change (`:161-164`):

```ruby
        if backoff
          self.class
            .set(wait: backoff)
            .perform_later(workflow.key, attempt: attempts_made, retry_counts: retry_counts)
        else
```

to:

```ruby
        if backoff
          enqueue_continuation(wait: backoff, attempt: attempts_made, retry_counts: retry_counts)
        else
```

- [ ] **Step 6: Convert the `wait` enqueue**

In `lib/chrono_forge/executor/methods/wait.rb`, change (`:105-111`):

```ruby
          # Reschedule the job
          self.class
            .set(wait: duration)
            .perform_later(@workflow.key)

          # Halt current execution
          halt_execution!
```

to:

```ruby
          # Record the reschedule; the executor publishes it after lock release.
          enqueue_continuation(wait: duration)

          # Halt current execution
          halt_execution!
```

- [ ] **Step 7: Convert both `wait_until` enqueues**

In `lib/chrono_forge/executor/methods/wait_until.rb`, change the cond-error retry (`:132-141`):

```ruby
            if backoff
              # Reschedule with the policy's backoff
              self.class
                .set(wait: backoff)
                .perform_later(
                  @workflow.key
                )

              # Halt current execution
              halt_execution!
```

to:

```ruby
            if backoff
              # Reschedule with the policy's backoff (published after lock release).
              enqueue_continuation(wait: backoff)

              # Halt current execution
              halt_execution!
```

Then change the poll reschedule (`:179-188`):

```ruby
          # Reschedule with delay
          self.class
            .set(wait: check_interval)
            .perform_later(
              @workflow.key,
              wait_condition: condition
            )

          # Halt current execution
          halt_execution!
```

to:

```ruby
          # Reschedule the poll (published after lock release).
          enqueue_continuation(wait: check_interval, wait_condition: condition)

          # Halt current execution
          halt_execution!
```

- [ ] **Step 8: Convert the `durably_execute` retry enqueue**

In `lib/chrono_forge/executor/methods/durably_execute.rb`, change (`:107-116`):

```ruby
            if backoff
              # Reschedule with the policy's backoff. The workflow replays on
              # resume and skips completed steps, so the rescheduled run picks
              # this step up again by its persisted execution log.
              self.class
                .set(wait: backoff)
                .perform_later(@workflow.key)

              # Halt current execution
              halt_execution!
```

to:

```ruby
            if backoff
              # Reschedule with the policy's backoff (published after lock release).
              # The workflow replays on resume and skips completed steps, so the
              # rescheduled run picks this step up again by its execution log.
              enqueue_continuation(wait: backoff)

              # Halt current execution
              halt_execution!
```

- [ ] **Step 9: Convert all three `durably_repeat` enqueues**

In `lib/chrono_forge/executor/methods/durably_repeat.rb`, `schedule_repetition_for_later` (`:191-197`):

```ruby
          # Schedule the workflow to run at the specified time
          self.class
            .set(wait: delay)
            .perform_later(@workflow.key)

          # Halt current execution until scheduled time
          halt_execution!
```

to:

```ruby
          # Schedule the workflow to run at the specified time (published after release).
          enqueue_continuation(wait: delay)

          # Halt current execution until scheduled time
          halt_execution!
```

The repetition retry (`:232-239`):

```ruby
          if backoff
            # Reschedule this same repetition with the policy's backoff
            self.class
              .set(wait: backoff)
              .perform_later(@workflow.key)

            # Halt current execution
            halt_execution!
```

to:

```ruby
          if backoff
            # Reschedule this same repetition with the policy's backoff (after release).
            enqueue_continuation(wait: backoff)

            # Halt current execution
            halt_execution!
```

And `schedule_next_execution_after_completion` (`:286-292`):

```ruby
          # Schedule the workflow to run for the next periodic execution
          self.class
            .set(wait: delay)
            .perform_later(@workflow.key)

          # Halt current execution
          halt_execution!
```

to:

```ruby
          # Schedule the next periodic execution (published after lock release).
          enqueue_continuation(wait: delay)

          # Halt current execution
          halt_execution!
```

- [ ] **Step 10: Run the new tests — expect PASS**

Run: `bundle exec ruby -Itest test/continuation_flush_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 11: Run the full suite — expect green**

Run: `bundle exec rake test`
Expected: all tests pass (retry/attempt threading preserved through the flush).

- [ ] **Step 12: Commit**

```bash
git add lib/chrono_forge/executor.rb \
        lib/chrono_forge/executor/methods/wait.rb \
        lib/chrono_forge/executor/methods/wait_until.rb \
        lib/chrono_forge/executor/methods/durably_execute.rb \
        lib/chrono_forge/executor/methods/durably_repeat.rb \
        test/continuation_flush_test.rb
git commit -m "fix(executor): publish continuations after lock release to close acquire race"
```

```json:metadata
{"files": ["lib/chrono_forge/executor.rb", "lib/chrono_forge/executor/methods/wait.rb", "lib/chrono_forge/executor/methods/wait_until.rb", "lib/chrono_forge/executor/methods/durably_execute.rb", "lib/chrono_forge/executor/methods/durably_repeat.rb", "test/continuation_flush_test.rb"], "verifyCommand": "bundle exec ruby -Itest test/continuation_flush_test.rb && bundle exec rake test", "acceptanceCriteria": ["continuations enqueued only after lock release", "per-site kwargs preserved", "flush no-ops without recorded continuation and is skipped when release_lock raises", "full suite green"], "requiresUserVerification": false}
```

---

### Task 2: Closed-form fast-forward of the expired prefix in `durably_repeat`

**Goal:** When `durably_repeat` resumes behind schedule, jump past the expired prefix in O(1), advance the coordination log's `last_execution_at`, and write one summary `ExecutionLog` for the skip — instead of one timed-out row + one zero-delay job per missed tick.

**Files:**
- Modify: `lib/chrono_forge/executor/methods/durably_repeat.rb` (call fast-forward in `durably_repeat` after `:149`; add private `fast_forward_expired_prefix`)
- Test: `test/durably_repeat_test.rb` (add new tests; update `test_durably_repeat_with_timeout` `:116` and `test_durably_repeat_coordination_log_updated_on_timeout` `:345`)

**Acceptance Criteria:**
- [ ] `fast_forward_expired_prefix` returns the input unchanged when nothing is expired (`next >= now − timeout`).
- [ ] When ticks are expired, it returns the first grid tick `>= now − timeout` (exact grid landing, `n = ceil((cutoff − next)/every)` intervals).
- [ ] The expired prefix produces **zero** `Execution timed out` rows and exactly **one** summary row (`error_class: "TimeoutError"`, `metadata["fast_forwarded"] == n`, step on the last skipped grid tick) that does not collide with the first-valid repetition row.
- [ ] Coordination `last_execution_at` is advanced to `(first_valid − every).iso8601`, so a replay is stable (recomputes the same `first_valid`).
- [ ] The first in-window tick still executes its work (boundary preserved).
- [ ] Full suite green.

**Verify:** `bundle exec ruby -Itest test/durably_repeat_test.rb` → all pass; then `bundle exec rake test` → green.

**Steps:**

- [ ] **Step 1: Write the failing unit test for the closed form**

Add to `test/durably_repeat_test.rb` (inside `class DurablyRepeatTest`):

```ruby
  def test_fast_forward_returns_input_when_nothing_expired
    workflow = ChronoForge::Workflow.create!(
      key: "ff_noop_#{rand(10_000)}", job_class: "KitchenSink",
      kwargs: {}, options: {}, context: {}, state: :idle
    )
    coordination = workflow.execution_logs.create!(
      step_name: "durably_repeat$x", state: :pending, metadata: {}
    )
    job = KitchenSink.new
    job.instance_variable_set(:@workflow, workflow)

    next_at = Time.current + 5.seconds # future tick, not expired
    result = job.send(:fast_forward_expired_prefix, coordination, next_at, 2.seconds, 1.hour)

    assert_in_delta next_at.to_f, result.to_f, 0.001, "future tick must be returned unchanged"
  end

  def test_fast_forward_lands_on_first_non_expired_grid_tick
    workflow = ChronoForge::Workflow.create!(
      key: "ff_jump_#{rand(10_000)}", job_class: "KitchenSink",
      kwargs: {}, options: {}, context: {}, state: :idle
    )
    coordination = workflow.execution_logs.create!(
      step_name: "durably_repeat$x", state: :pending, metadata: {}
    )
    job = KitchenSink.new
    job.instance_variable_set(:@workflow, workflow)

    every   = 1.second
    timeout = 1.second
    # 60 ticks back, 1s grid, 1s timeout => cutoff = now-1s; first non-expired
    # tick is the smallest grid tick >= now-1s.
    next_at = Time.current - 60.seconds
    cutoff  = Time.current - timeout

    result = job.send(:fast_forward_expired_prefix, coordination, next_at, every, timeout)

    # On-grid: result == next_at + n*every for integer n.
    n = ((result - next_at) / every.to_f).round
    assert_in_delta next_at.to_f + n * every.to_f, result.to_f, 0.001, "result must stay on the grid"
    assert_operator result, :>=, cutoff, "result must be the first non-expired tick"
    assert_operator result - every, :<, cutoff, "the tick before result must still be expired"

    # Coordination advanced so replay recomputes the same first_valid.
    coordination.reload
    assert coordination.metadata["last_execution_at"], "last_execution_at must be set"
    assert_in_delta (result - every).to_f,
      Time.parse(coordination.metadata["last_execution_at"]).to_f, 0.001

    # Exactly one summary row written, on the last skipped grid tick, with the count.
    summary = workflow.execution_logs.where("step_name LIKE ?", "durably_repeat$x$%").to_a
    assert_equal 1, summary.size, "exactly one summary row for the skipped prefix"
    assert_equal "TimeoutError", summary.first.error_class
    assert_operator summary.first.metadata["fast_forwarded"].to_i, :>=, 1
  end
```

- [ ] **Step 2: Run unit tests to verify they fail**

Run: `bundle exec ruby -Itest test/durably_repeat_test.rb -n "/fast_forward/"`
Expected: FAIL — `NoMethodError: undefined method 'fast_forward_expired_prefix'`.

- [ ] **Step 3: Implement `fast_forward_expired_prefix` and wire it in**

In `lib/chrono_forge/executor/methods/durably_repeat.rb`, in `durably_repeat`, insert the call right after `next_execution_at` is computed (after `:149`, before `execute_or_schedule_repetition` at `:151`):

```ruby
          next_execution_at = fast_forward_expired_prefix(coordination_log, next_execution_at, every, timeout)

          execute_or_schedule_repetition(method, coordination_log, next_execution_at, every, policy, timeout, on_error)
```

Add the private method (alongside the other privates):

```ruby
        # Catch-up fast-forward. A tick `t` is expired (its work is skipped) iff
        # `Time.current > t + timeout`, i.e. `t < now - timeout`. Rather than
        # walking one zero-delay job per expired tick, jump straight to the first
        # non-expired tick on the same grid in closed form.
        #
        # Anchoring the arithmetic on `next_execution_at` (already on the canonical
        # grid: start_at / created_at+every / last_execution_at+every all land on
        # it, because last_execution_at stores the *scheduled* time, not wall-clock)
        # keeps the result exactly on the grid — no drift.
        #
        # Returns `next_execution_at` unchanged when nothing is expired. Otherwise
        # advances the coordination log's last_execution_at so a replay recomputes
        # the same first tick, and writes ONE summary ExecutionLog for the whole
        # skipped prefix (no per-tick timeout rows).
        def fast_forward_expired_prefix(coordination_log, next_execution_at, every, timeout)
          cutoff = Time.current - timeout
          return next_execution_at if next_execution_at >= cutoff

          n = ((cutoff - next_execution_at) / every.to_f).ceil
          first_valid = next_execution_at + (n * every)
          last_skipped = first_valid - every

          Rails.logger.info {
            "ChronoForge:#{self.class}(#{@workflow.key}) durably_repeat fast-forwarded " \
            "#{n} expired tick(s) to #{first_valid.iso8601}"
          }

          # Single summary row for the skipped prefix, on the last skipped grid
          # tick (unique; never collides with the first_valid repetition row).
          summary_step = "#{coordination_log.step_name}$#{last_skipped.to_i}"
          find_or_create_execution_log!(summary_step) do |log|
            log.started_at = Time.current
            log.metadata = {
              fast_forwarded: n,
              from: next_execution_at.iso8601,
              to: last_skipped.iso8601,
              scheduled_for: last_skipped,
              timeout_at: last_skipped + timeout,
              parent_id: coordination_log.id
            }
          end.update!(
            state: :failed,
            error_class: "TimeoutError",
            error_message: "Fast-forwarded #{n} expired tick(s)",
            completed_at: Time.current
          )

          # Record progress: a replay recomputes naive_next = last + every = first_valid.
          coordination_log.update!(
            metadata: coordination_log.metadata.merge("last_execution_at" => last_skipped.iso8601)
          )

          first_valid
        end
```

- [ ] **Step 4: Run unit tests — expect PASS**

Run: `bundle exec ruby -Itest test/durably_repeat_test.rb -n "/fast_forward/"`
Expected: PASS (2 tests).

- [ ] **Step 5: Add an integration test for catch-up (red→green in one step since impl now exists)**

Add to `test/durably_repeat_test.rb` (class body + a job class at the bottom with the others):

```ruby
  def test_durably_repeat_catch_up_fast_forwards_expired_prefix
    unique_key = "catchup_#{Time.now.to_i}_#{rand(10_000)}"

    # start_at far in the past with a short timeout => a long expired prefix.
    CatchUpJob.perform_later(unique_key, start_time: Time.current - 60.seconds)

    perform_all_jobs_before(5.seconds)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # No per-tick timeout tombstones for the expired prefix.
    timed_out = workflow.execution_logs.select { |l| l.error_message == "Execution timed out" }
    assert_empty timed_out, "expired prefix must not create per-tick timeout rows"

    # Exactly one fast-forward summary row.
    summaries = workflow.execution_logs.select { |l| l.metadata && l.metadata["fast_forwarded"] }
    assert_equal 1, summaries.size, "expired prefix collapses to one summary row"
    assert_operator summaries.first.metadata["fast_forwarded"].to_i, :>=, 1
  end
```

```ruby
class CatchUpJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform(start_time:)
    context.set_once(:execution_count, 0)
    start_obj = start_time.is_a?(String) ? Time.parse(start_time) : start_time
    durably_repeat :catch_up_task, every: 1.second, till: :done?,
      start_at: start_obj, timeout: 1.second
  end

  private

  def catch_up_task(_scheduled = nil)
    context[:execution_count] = context.fetch(:execution_count, 0) + 1
  end

  def done?
    context.fetch(:execution_count, 0) >= 1
  end
end
```

- [ ] **Step 6: Update the two existing timeout tests to the new behavior**

In `test/durably_repeat_test.rb`, `test_durably_repeat_with_timeout` (`:116-131`) — replace the timeout-tombstone assertion. Change:

```ruby
    # Should have timeout failures
    timeout_logs = workflow.execution_logs.select { |log|
      log.failed? && log.error_message == "Execution timed out"
    }
    assert_operator timeout_logs.size, :>, 0, "should have timeout failures"
```

to:

```ruby
    # Expired ticks are now fast-forwarded: no per-tick "Execution timed out"
    # rows; the skipped prefix collapses to a single fast_forwarded summary row.
    timeout_logs = workflow.execution_logs.select { |log|
      log.error_message == "Execution timed out"
    }
    assert_empty timeout_logs, "expired ticks should be fast-forwarded, not tombstoned per tick"

    summaries = workflow.execution_logs.select { |log| log.metadata && log.metadata["fast_forwarded"] }
    assert_operator summaries.size, :>=, 1, "should record a fast-forward summary row"
```

Then `test_durably_repeat_coordination_log_updated_on_timeout` (`:345-384`) — change the same tombstone block (`:369-373`):

```ruby
    # Find timeout logs
    timeout_logs = workflow.execution_logs.select { |log|
      log.failed? && log.error_message == "Execution timed out"
    }
    assert_operator timeout_logs.size, :>, 0, "should have timeout failures"
```

to:

```ruby
    # Expired ticks are fast-forwarded into a single summary row, not per-tick rows.
    summaries = workflow.execution_logs.select { |log| log.metadata && log.metadata["fast_forwarded"] }
    assert_operator summaries.size, :>=, 1, "should record a fast-forward summary row"
```

(The remaining assertions in that test — `last_execution_at` is present and advanced — still hold and stay unchanged.)

- [ ] **Step 7: Run the durably_repeat suite — expect PASS**

Run: `bundle exec ruby -Itest test/durably_repeat_test.rb`
Expected: PASS (all, including updated timeout tests).

- [ ] **Step 8: Run the full suite — expect green**

Run: `bundle exec rake test`
Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add lib/chrono_forge/executor/methods/durably_repeat.rb test/durably_repeat_test.rb
git commit -m "fix(durably_repeat): fast-forward expired catch-up prefix in closed form"
```

```json:metadata
{"files": ["lib/chrono_forge/executor/methods/durably_repeat.rb", "test/durably_repeat_test.rb"], "verifyCommand": "bundle exec ruby -Itest test/durably_repeat_test.rb && bundle exec rake test", "acceptanceCriteria": ["fast_forward returns input when nothing expired", "lands on first non-expired grid tick (no drift)", "zero per-tick timeout rows + exactly one summary row", "coordination last_execution_at advanced for stable replay", "first in-window tick still executes", "full suite green"], "requiresUserVerification": false}
```

---

## Self-Review

- **Spec coverage:** Section 1 (deferred flush, all 8 sites) → Task 1. Section 2 (closed-form fast-forward, summary row, coordination advance, test updates) → Task 2. Both covered.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type/name consistency:** `enqueue_continuation`/`flush_continuation!`/`@continuation`/`fast_forward_expired_prefix` used identically across plan and tests. Summary metadata key `fast_forwarded` consistent in impl and all assertions.
- **Verification scan:** spec requires no human-in-the-loop verification → User Verification = NO; no verification task needed.
