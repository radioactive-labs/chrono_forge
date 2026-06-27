# ChronoForge — deferral continuation race & catch-up surge

**Date:** 2026-06-26
**Gem:** `chrono_forge` 0.9.1
**Status:** design approved, ready for implementation plan

## Problem

Two related findings in how ChronoForge's deferral primitives (`wait`, `wait_until`,
`durably_execute` retry, `durably_repeat`, workflow-level retry) schedule their
continuation jobs. Both are functionally benign in 0.9.1 (no lost work, no double
execution) but generate avoidable job/lock churn and log noise, and they interact.

### Issue 1 — continuation/lock-release race (`ConcurrentExecutionError`)

Every deferral primitive enqueues its continuation **inline** and then halts:

```ruby
self.class.set(wait: delay).perform_later(@workflow.key)   # (1) enqueue continuation
halt_execution!                                            # (2) raise HaltExecutionFlow
```

The executor releases the lock in `ensure`, **after** the body runs
(`executor.rb:168-172`). So within one job run the order is: **enqueue continuation →
halt → (ensure) release lock.** The continuation is published while the current job
still holds the lock.

When the continuation is **immediately runnable** (`delay == 0`), SolidQueue puts it
straight in `ready_executions`. With multiple workers, a free worker can claim and
start it in the window between (1) and the `ensure` release. That second job calls
`acquire_lock`, finds `locked_at > max_duration.ago` (still freshly held by the first
job), and raises `ConcurrentExecutionError` at lock acquisition (failing
`execution_log.step_name` is `nil` — before any step).

`delay == 0` arises when:
- `wait` targets computed against wall-clock times already in the past on replay, and
- **every fast-forwarded tick in Issue 2** (`delay = max(next − now, 0) = 0`).

Benign today (loser is rescued, winner proceeds, continuation replays idempotently),
but costs wasted job executions, redundant lock attempts, and log noise.

### Issue 2 — catch-up is O(missed intervals)

When a `durably_repeat` workflow resumes far behind schedule, each missed tick is
handled by `execute_repetition_now`. For an expired tick it correctly **skips the
periodic method**, but then advances by exactly **one interval** and enqueues a **new
job** (`durably_repeat.rb:200-212`, `:271-293`):

```ruby
if Time.current > repetition_log.metadata["timeout_at"]
  repetition_log.update!(state: :failed, error_class: "TimeoutError")
  schedule_next_execution_after_completion(...)   # advance ONE interval + enqueue a job
  return                                           # method NOT run (work correctly skipped)
end
```

So expiry is a **work skip, not an iteration skip**. Walking a workflow from a far-past
`start_at` up to `now` churns through **one `delay == 0` job per missed interval** — each
job marks one tick timed-out, schedules the next, and halts. Resuming ~14 dormant
daily/weekly schedulers generated ~6,000 back-to-back `delay == 0` jobs. Every one of
those is the maximal trigger for Issue 1.

Worst case: a workflow resuming from genesis (no prior coordination/repetition logs)
with an ancient `start_at`.

## Enqueue sites (complete inventory)

All 8 continuation enqueues are `.set(wait:).perform_later`; `continue_if` halts with no
continuation (it waits for an external trigger — correctly needs no fix).

| # | Site | kwargs passed | delay |
|---|------|---------------|-------|
| 1 | `executor.rb:163` workflow retry | `attempt:, retry_counts:` | backoff |
| 2 | `wait.rb:107` reschedule | — | duration |
| 3 | `wait_until.rb:135` cond-error retry | — | backoff |
| 4 | `wait_until.rb:181` poll | `wait_condition:` | check_interval |
| 5 | `durably_execute.rb:112` retry | — | backoff |
| 6 | `durably_repeat.rb:193` schedule-later | — | delay |
| 7 | `durably_repeat.rb:235` repetition retry | — | backoff |
| 8 | `durably_repeat.rb:288` schedule-next | — | delay (=0 in surge) |

## Fix — Section 1: deferred continuation flush

Primitives stop calling `perform_later` inline. They **record** the intended
continuation on the instance; the executor flushes it in `ensure`, **after**
`release_lock`. The continuation becomes claimable only once the lock row reads
released, so no second worker can lose the acquire race. This is the report's
**option 1** (fully closes the window), not option 3 (epsilon delay heuristic).

**Single slot suffices.** Every primitive enqueues at most one continuation and then
either raises `HaltExecutionFlow` (sites 2–8) or falls through `rescue => e` into
`ensure` (site 1). No path schedules two.

```ruby
# executor.rb — new private helper
def enqueue_continuation(wait:, **kwargs)
  @continuation = {wait: wait, kwargs: kwargs}
end
```

Each of the 8 sites changes from:

```ruby
self.class.set(wait: delay).perform_later(@workflow.key)   # or with kwargs
halt_execution!
```

to:

```ruby
enqueue_continuation(wait: delay)                          # kwargs preserved per-site
halt_execution!
```

Flush in `ensure` (`executor.rb:168`), strictly ordered after release:

```ruby
ensure
  if lock_acquired
    context.save!
    self.class::LockStrategy.release_lock(job_id, workflow)
    flush_continuation!                  # NEW — only now is the next job claimable
  end
end

def flush_continuation!
  return unless @continuation
  self.class.set(wait: @continuation[:wait]).perform_later(@workflow.key, **@continuation[:kwargs])
end
```

**Ordering guarantee:** `save! → release_lock → flush`. The continuation is published
only after the lock row is updated to released, so even a `delay == 0` continuation
finds the lock free.

**Edge cases:**
- If `release_lock` raises `LongRunningConcurrentExecutionError` (this job overran
  `max_duration` and lost the lock), we do **not** flush — correct, another job already
  owns the continuation.
- Site 1 (workflow retry) isn't a halt, but routing it through the same slot keeps all
  enqueues post-release and is harmless (backoff is normally > 0 anyway).
- `@continuation` is per-job-execution instance state; nil unless a primitive set it.

## Fix — Section 2: closed-form fast-forward of the expired prefix

In `durably_repeat` (`durably_repeat.rb:143-151`), after the naive `next_execution_at`
is computed and before `execute_or_schedule_repetition`, jump past the expired prefix in
closed form instead of walking one job per tick.

**Skip rule (from the code):** a tick `t` is expired iff `Time.current > t + timeout`,
i.e. `t < now − timeout`. Find the smallest tick on the grid `next_execution_at + n·every`
(n ≥ 0) that is **not** expired (`t ≥ now − timeout`):

```ruby
def fast_forward_expired_prefix(next_execution_at, every, timeout)
  cutoff = Time.current - timeout
  return next_execution_at if next_execution_at >= cutoff   # nothing expired

  gap = cutoff - next_execution_at
  n = (gap / every.to_f).ceil                               # n ≥ 1 here
  Rails.logger.info {
    "ChronoForge:#{self.class}(#{@workflow.key}) durably_repeat fast-forwarded #{n} expired tick(s)"
  }
  next_execution_at + (n * every)
end
```

**Why anchor on `next_execution_at`, not `start_at`.** `next_execution_at` is always
already on the canonical grid `anchor + k·every`:

1. `start_at` given, no `last_execution_at` → `next = start_at`. On-grid (k=0).
2. No `start_at`, no `last_execution_at` → `next = created_at + every`. On-grid (k=0).
3. `last_execution_at` present → `next = last_execution_at + every`. On-grid because
   `last_execution_at` stores the **scheduled** tick time, not wall-clock:
   `schedule_next_execution_after_completion` writes `current_execution_time.iso8601`
   (`durably_repeat.rb:275`), where `current_execution_time` is the scheduled tick, not
   `Time.current`. By induction, lateness never enters the recurrence.

So jumping by integer multiples of `every` from `next_execution_at` stays exactly on the
grid — **no drift**. Anchoring the ceil on `start_at` (as the report's formula literally
writes) would compute against a different anchor than the grid the workflow is actually
on (branches 2 and 3) and could land between real ticks.

**Boundary correctness — only the expired prefix is skipped.** The jump lands on the
first tick with `t ≥ now − timeout`, which is either:
- **in-window** (`now − timeout ≤ t ≤ now`): `execute_or_schedule_repetition` sees
  `t ≤ now` → runs `execute_repetition_now`, which re-checks `now > timeout_at` (now
  false) → **executes the work**. Legitimate catch-up preserved.
- **future** (`t > now`): → `schedule_repetition_for_later`. Normal.

If `timeout > every` there can be several in-window ticks; those still walk one job each
by design (real work, not bookkeeping). Only the expired prefix collapses to O(1).

**Coordination-log bookkeeping.** As part of the fast-forward, set the coordination
log's `last_execution_at = (first_valid − every).iso8601` (same format the reader
`Time.parse` expects). A replay then recomputes `naive_next = last_execution_at + every
= first_valid` — stable and idempotent — and the expired prefix produces **one metadata
update** instead of N `failed/TimeoutError` repetition rows and N jobs.

**One summary row for the skipped prefix (decided).** Instead of N `failed/TimeoutError`
repetition rows, the fast-forward writes a **single** durable `ExecutionLog` covering the
whole skipped prefix, so the skip stays dashboard-visible and queryable:

- **step_name:** `durably_repeat$<name>$<last_skipped_tick.to_i>`, where
  `last_skipped_tick = first_valid − every`. This is the last expired grid tick, so it is
  unique and **never collides** with the repetition row for `first_valid` (the first
  in-window/future tick, which `execute_or_schedule_repetition` still creates and runs).
- **state:** `failed` (the enum has only `pending/completed/failed` — no migration),
  **error_class:** `"TimeoutError"`, **error_message:** `"Fast-forwarded N expired tick(s)"`.
- **metadata:** `{ fast_forwarded: N, from: <first_expired.iso8601>,
  to: <last_skipped.iso8601>, scheduled_for: <last_skipped>, timeout_at: <last_skipped + timeout>,
  parent_id: <coordination_log.id> }` — mirrors the existing repetition-log metadata shape
  plus the `fast_forwarded`/`from`/`to` summary fields.

Created via `find_or_create_execution_log!`, so it is idempotent on replay (and the
3-segment step name is correctly excluded from `completed_step_cache`, matching ordinary
repetition logs). A `Rails.logger.info { "...fast-forwarded N expired tick(s)" }` line is
also emitted for ops. This is a deliberate behavior change from 0.9.1's one-row-per-tick.

The existing dashboard step-name parser already handles 3-segment
`durably_repeat$<name>$<ts>` repetition steps, so **no dashboard change is required** for
this plan; the summary row renders like any other repetition log.

**Observable-behavior change → existing tests updated.** Two tests assert the old
per-tick tombstones via `timeout: -1.second` and must be updated to the new behavior:
- `durably_repeat_test.rb:116` `test_durably_repeat_with_timeout` — asserts
  `timeout_logs.size > 0` (filtering `error_message == "Execution timed out"`); flip to
  asserting **no** `Execution timed out` rows and exactly **one** `fast_forwarded` summary
  row for the expired prefix.
- `durably_repeat_test.rb:345` `test_durably_repeat_coordination_log_updated_on_timeout`
  — its `last_execution_at`-advances assertion still holds; its `timeout_logs.size > 0`
  assertion flips to asserting the single `fast_forwarded` summary row instead.

The `wait_until` negative-timeout test (`error_log_correlation_test.rb:23`) is a
different primitive and is unaffected. Catch-up tests using the default positive timeout
(`test_durably_repeat_with_past_start_at`, etc.) are unaffected because nothing is
expired under a 1-hour window.

**Idempotency / replay safety.** The skipped ticks never get repetition logs, but
they're never recomputed either (the jump advances `last_execution_at` past them), and
all execution-log lookups are by exact `step_name` — nothing scans for the missing rows.
Prior completed/failed ticks from before dormancy are untouched.

## Interaction

The two share a root: continuations are published as immediately-claimable, same-key
jobs while/just-before the lock is released. The catch-up surge (Issue 2) is the
maximal trigger for the race (Issue 1). Section 1 closes the race structurally;
Section 2 removes the burst of `delay == 0` continuations that most reliably arms it.
Both together remove the class of problem.

## Testing

- **Issue 1:** unit-test that each of the 8 primitives sets `@continuation` and does
  **not** call `perform_later` inline; that the executor flushes after `release_lock`
  (assert ordering — e.g. the enqueue observes the lock row released); that
  `LongRunningConcurrentExecutionError` from `release_lock` suppresses the flush; that
  per-site kwargs (`attempt`/`retry_counts`, `wait_condition`) are preserved.
- **Issue 2:** unit-test `fast_forward_expired_prefix` returns `next_execution_at`
  unchanged when nothing is expired; lands exactly on the first non-expired grid tick;
  is on-grid across all three anchor branches; that an in-window first tick executes its
  work while the expired prefix creates no repetition rows; that `last_execution_at` is
  advanced so a replay is stable. Integration: resume a far-past daily schedule and
  assert O(1) jobs/log rows for the expired prefix instead of O(missed intervals).
```
