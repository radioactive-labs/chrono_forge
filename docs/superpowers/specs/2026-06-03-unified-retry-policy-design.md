# Unified RetryPolicy — Design

**Date:** 2026-06-03
**Status:** Approved (pending spec review)
**Scope:** Internal API. No external callers; clean break, no deprecation shim.

## Problem

ChronoForge currently has three independent retry systems, two backoff
algorithms, and three different "should we retry?" decision models:

1. **Workflow-level** (uncaught errors in `perform`)
   - `should_retry?(error, attempt)` → hardcoded `attempt < 3`, ignores the error
   - `RetryStrategy.schedule_retry` → fixed array `[1s, 5s, 30s, 2m, 10m]`
   - guard: `attempt >= RetryStrategy.max_attempts` (= 5)
   - **Dead config:** `should_retry?` stops at 3, so the array's `2m`/`10m`
     entries and `max_attempts == 5` are unreachable.

2. **Step-level** (`durably_execute`, `durably_repeat`)
   - `max_attempts:` param (default 3)
   - backoff `2**[attempts, 5].min` — a *different* algorithm (exponential,
     32s cap) than the workflow level
   - `durably_repeat` adds `on_error: :continue | :fail_workflow`
   - **Dead arg:** the reschedule passes `retry_method:`, which `perform`'s
     signature never binds — it falls into `**kwargs` and is ignored. Replay
     skipping completed steps is what actually resumes the step, not this arg.

3. **`wait_until`**
   - `retry_on: [ExceptionClass, …]` — a third model (error-class allowlist)
   - no attempt cap (bounded by `timeout`), same `2**n` backoff

Additional finding: workflow-level attempts (the `attempt:` job arg, lives only
in the job payload) and step attempts (`execution_log.attempts`, a DB column)
are unrelated counters.

Net: backoff is implemented twice and configurable nowhere per-call; "should we
retry?" is answered three ways (attempt-count / max_attempts / error-class); and
the workflow-level cap is internally contradictory (3 vs 5).

## Goal

Collapse to **one** `RetryPolicy` type with **one** backoff algorithm, used by
all four sites. Today's three behaviors become three *default configurations* of
the same type. Retry behavior becomes expressible per-call.

The unification is of **type + mechanism**, not of default *values*: each call
site keeps a default tuned to its purpose, but all defaults are instances of the
same object and all are overridable.

## Decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| Ambition | Option A — one unified `RetryPolicy`, `wait_until` folded in |
| Backoff curve | Exponential + jitter, single default, per-call overridable |
| Compatibility | Clean break — internal code, fix all call sites in the same change |
| Surface | Class-level default DSL + per-call `retry_policy:` override |
| Attempt counters | Workflow-level stays in the `attempt:` job arg; steps stay on `execution_log.attempts`. Policy unifies; counting storage does not (no migration) |
| `wait_until` poll cadence | Stays **out** of `RetryPolicy` (`check_interval`/`timeout` are polling, not retry) |
| Per-site backoff defaults | Steps `max_attempts: 3, cap: 30`. Workflow-level `max_attempts: 10, cap: 600` — a ~8.5 min tolerant window for transient infra errors on uncaught `perform` errors (revised post-review from an inconsistent `8/600`, where the 600 cap was unreachable). `cap: 600` is a per-delay ceiling, not a dead default: it binds when a caller configures more attempts. |

## Design

### 1. `RetryPolicy` value object

New file: `lib/chrono_forge/executor/retry_policy.rb`

```ruby
RetryPolicy.new(
  max_attempts: 3,        # Integer cap, or nil = no count cap (bounded elsewhere)
  base: 1,                # seconds
  cap: 30,                # seconds, max single delay
  jitter: true,
  retry_on: nil           # nil = retry any StandardError; [Classes] = only these
)
```

Two methods are the entire decision surface. `attempts` is the 1-based count of
attempts made so far, *including* the one that just failed (matching
`ExecutionLog#attempts`); on the first failure `attempts == 1`.

- `retryable?(error, attempts)` →
  `(max_attempts.nil? || attempts < max_attempts)` **and** the error matches
  `retry_on` (`retry_on.nil?` means any `StandardError`; otherwise
  `retry_on.any? { |k| error.is_a?(k) }`).
- `backoff_for(attempts)` → `delay = [cap, base * 2**(attempts - 1)].min`, then
  equal jitter when enabled: `delay / 2.0 + rand(0.0..delay / 2.0)`. Returns an
  `ActiveSupport::Duration` suitable for `set(wait:)`.

**Jitter & determinism:** `backoff_for` is called once, at the moment a retry
job is re-enqueued. The result is never persisted or replayed, so `rand`
introduces no replay nondeterminism. (Stated explicitly because this is a
replay engine.)

### 2. Per-site default policies

A single gem-wide default, overridable per class and per call. Two sites need
distinct *defaults* to preserve current semantics:

| Site | Default policy | Rationale (= today's behavior) |
|---|---|---|
| `durably_execute`, `durably_repeat` | `max_attempts: 3, base: 1, cap: 30, retry_on: nil` (retry **all** errors) | matches current `rescue => e; retry`; flaky calls fast-fail |
| Workflow-level | `max_attempts: 10, base: 1, cap: 600, retry_on: nil` | only fires on uncaught `perform` errors (step failures stall instead), which are rare and may be transient infra blips. 10 attempts ≈ 8.5 min window rides those out; each retry replays the whole workflow, so the count is bounded rather than open-ended. `cap: 600` (10 min) ceils any single backoff |
| `wait_until` (error path) | `retry_on: []` (retry **nothing** by default) | a condition that *raises* is usually a bug, not transient — matches current `retry_on: []` |

`wait_until`'s polling cadence (`check_interval` / `timeout`) is **not** retry
and is untouched. `RetryPolicy` governs only what happens when the condition
*raises*.

### 3. Surface — class default + per-call override

```ruby
class ChargeWorkflow < ApplicationJob
  prepend ChronoForge::Executor
  retry_policy max_attempts: 5, base: 2, cap: 60   # class-wide default

  def perform
    durably_execute :charge, retry_policy: RetryPolicy.new(max_attempts: 8, retry_on: [Net::OpenTimeout])
    wait_until :settled?, retry_policy: RetryPolicy.new(retry_on: [BankApiError])
  end
end
```

`retry_policy(**)` is a class-level DSL added by the prepended `Executor` that
builds and stores a `RetryPolicy` in `default_retry_policy` (a `class_attribute`,
so it inherits). The per-call kwarg is named `retry_policy:` (not `retry:`)
because `retry` is a Ruby keyword — a `retry:` parameter could not be read inside
the method without `binding.local_variable_get(:retry)`. `retry_policy:` also
reads consistently with the class-level DSL.

**Resolution rules (precise — to remove ambiguity):**

- **Error-retry sites** (`durably_execute`, `durably_repeat`, workflow-level):
  explicit per-call `retry_policy:` → class `default_retry_policy` → that site's
  built-in default (table above). So a declared class default replaces the
  built-in for *both* steps and the workflow level, collapsing their differing
  built-ins (3/30 vs 5/30) onto one value. This is the intended, predictable
  meaning of "class-wide default."
- **`wait_until`** does **not** inherit the class `default_retry_policy`. It uses
  its built-in `retry_on: []` unless an explicit per-call `retry_policy:` is passed.
  Rationale: a class-wide "retry all errors 5×" must not silently turn
  condition-evaluation bugs into retried errors. `wait_until`'s retry set is a
  deliberate per-call opt-in, not a class-wide inheritance.

### 4. Integration / deletions

- **Delete** `lib/chrono_forge/executor/retry_strategy.rb` (`RetryStrategy`).
- **Delete** private `should_retry?` in `executor.rb` (the dead `attempt < 3`).
- **Delete** the dead `retry_method:` arg in `durably_execute`'s reschedule.
- **Replace** the `max_attempts:` / `retry_on:` kwargs on `durably_execute`,
  `durably_repeat`, and `wait_until` with a single `retry_policy:` kwarg.
- **`executor.rb#perform`:** the resolved policy here is `default_retry_policy`
  (class DSL) or the workflow-level built-in (`max_attempts: 10, cap: 600`);
  there is no per-call `retry_policy:` since an uncaught error has no call site.
  - top guard becomes `attempt >= resolved_policy.max_attempts`
  - the `rescue => e` block routes through the resolved policy:
    ```ruby
    if policy.retryable?(e, attempt)
      self.class.set(wait: policy.backoff_for(attempt)).perform_later(key, attempt: attempt + 1)
    else
      fail_workflow!(error_log)
    end
    ```
- **`durably_execute` / `durably_repeat`:** on error, use
  `policy.retryable?(e, execution_log.attempts)` and
  `policy.backoff_for(execution_log.attempts)`; otherwise mark failed and raise
  `ExecutionFailedError` (`durably_repeat` keeps its `on_error` branch).
- **`wait_until`:** replace the `retry_on.include?(e.class)` check and the
  inline `2**n` backoff with the resolved policy. The poll/timeout path is
  unchanged.

The old extensibility model — `self.class::RetryStrategy` magic constant +
overriding private `should_retry?` — is removed in favor of passing a
`RetryPolicy`.

### 5. Backoff impact (informational)

Delays in seconds; current step/wait curve is `2**min(attempts,5)`, current
workflow curve is the fixed array (truncated at attempt 3 by the dead config).

| Site | Today (actual) | New default |
|---|---|---|
| `durably_execute`/`durably_repeat` (`max_attempts:3`) | `2, 4` then fail | `~1, ~2` (jittered) then fail |
| `wait_until` error path | `2, 4, 8, …` cap 32 | unchanged in shape; cap 30 |
| Workflow-level | `1, 5, 30` then fail | `~1, 2, 4, 8, 16, 32, 64, 128, 256` (jittered) then fail, `max_attempts:10` (~8.5 min) |

Steps and `wait_until` are effectively unchanged (jitter added, cap 32→30). The
workflow level keeps the array's intended 5-attempt count but with one curve;
it does **not** add a long backoff tail — each workflow-level retry replays the
whole workflow, so the attempt count is deliberately kept modest.

## Files touched

- **New:** `lib/chrono_forge/executor/retry_policy.rb`
- **Delete:** `lib/chrono_forge/executor/retry_strategy.rb`
- **Edit:** `lib/chrono_forge/executor.rb` (perform rescue + guard, remove
  `should_retry?`), `lib/chrono_forge/workflow.rb` (add `retry_policy` DSL +
  `default_retry_policy`), `lib/chrono_forge/executor/methods/durably_execute.rb`,
  `.../durably_repeat.rb`, `.../wait_until.rb`
- **Edit:** test suite, example workflows, and `README.md` retry sections
  (~lines 165–261, 393, 765–769) — clean break, all call sites updated together

## Testing

**`RetryPolicy` unit tests**
- `retryable?` truth table: count cap reached/not; `max_attempts: nil` (never
  count-capped); `retry_on: nil` (any StandardError); `retry_on: [A]` match and
  miss; `retry_on: []` (never).
- `backoff_for`: exponential growth; cap clamp; jitter bounds with a
  seeded/stubbed `rand`; `jitter: false` is exact.

**Integration (per method)**
- retries → succeeds; retries → exhausts → fails (`ExecutionFailedError` /
  `fail_workflow!`); per-call `retry_policy:` override is honored.
- `wait_until`: fails fast on an unlisted error; retries a listed one; poll
  cadence/timeout unaffected.
- workflow-level: uncaught error retries with `attempt+1` and the workflow-level
  policy; stops at `max_attempts`.
- `durably_repeat`: `on_error: :continue` vs `:fail_workflow` still branch
  correctly after exhaustion.

## Out of scope

- Migrating workflow-level attempt counting into the DB (explicitly deferred).
- Changing `wait_until`'s polling model (`check_interval`/`timeout`).
- `durably_repeat`'s `on_error` semantics (kept as-is).
