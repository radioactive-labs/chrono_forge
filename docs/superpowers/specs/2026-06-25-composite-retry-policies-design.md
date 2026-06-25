# Composite Retry Policies — Design

**Date:** 2026-06-25
**Status:** Approved (pending spec review)
**Scope:** Internal API, additive. Builds on the unified `RetryPolicy`
(2026-06-03). No breaking change — the common single-policy path is byte-for-byte
unchanged.

## Problem

The unified `RetryPolicy` answers "should we retry?" with a single
`max_attempts`/`backoff`/`retry_on` tuple per retry site. A single tuple cannot
express *different behavior per error type* — yet that is exactly what real
workflows (fintech especially) need:

- `NetworkError` → retry aggressively, short backoff
- `RateLimitError` → retry more, longer backoff
- `PaymentDeclinedError` → fail immediately, do not retry

Today you must pick one policy for the whole step. A `retry_on:` allowlist filters
*which* errors retry, but every retried error shares one `max_attempts` and one
backoff curve.

## Goal

Let a retry site be configured with an **ordered list** of `RetryPolicy` objects.
On failure, the **first** sub-policy whose `retry_on` matches the raised error
applies its own `max_attempts`/`backoff`. Each error type gets an **independent
attempt budget**.

The single-policy path is untouched: it keeps using the site's own `attempts`
counter, with no extra state.

## Decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| Counting semantics | **Per-error budgets.** A sub-policy's `max_attempts` counts only failures routed to it. |
| Where the count lives | A `retry_counts` map keyed by **matched-policy index**. Steps: in the (execution/repetition) log `metadata`. Workflow-level: in the job args, beside `attempt:`. No new column, no `error_logs` query. |
| Subclass safety | Routing happens **once, on the live error** via `matches?`/`is_a?` — subclass-correct. The count is keyed by the matched policy, never by error class, so no constantizing or class-string matching at decision time. |
| Single-policy path | Unchanged — uses the site's `attempts` counter directly, no `retry_counts`. |
| Construction | Named factory `RetryPolicy.compose(*policies)`; passing an `Array` to `retry_policy:` coerces through the same factory. |
| Scope | **All four sites**, including the workflow-level class default. |
| Routing | First match wins. `retry_on: nil` (catch-all) typically last; no match → no retry (fail fast). |
| Purity | `RetryPolicy` and `CompositeRetryPolicy` stay pure value objects. The per-error count is incremented/read by the executor via a block; the policies never touch storage. |

## Why increment-then-check preserves existing semantics

`attempts` is 1-based and includes the failure that just happened (so on the
first failure `attempts == 1`, and `retryable?` checks `attempts < max_attempts`).
The composite mirrors this: on each failure it **increments** the matched
policy's counter **then** checks, so the value handed to `retryable?` is "failures
routed to this policy so far, including the current one" — the same shape the
single-policy path already uses. The two notions agree, so a per-error count
substitutes cleanly wherever a plain policy uses `attempts`.

## Components

### 1. `RetryPolicy` (existing — additions, pure)

- `matches?(error)` — public routing predicate; wraps the existing private
  `retryable_error?`. `retry_on: nil` matches any `StandardError` (catch-all);
  `retry_on: []` matches nothing. Subclass-correct (`error.is_a?`).
- `retry_backoff(error, attempts:) { |policy_index| count }` — returns the backoff
  `Duration` to retry, or `nil` to stop. The plain policy **ignores the block**
  and uses `attempts`:

  ```ruby
  def retry_backoff(error, attempts:)
    retryable?(error, attempts) ? backoff_for(attempts) : nil
  end
  ```

- `self.compose(*policies)` — factory returning a `CompositeRetryPolicy`.

`retryable?`, `backoff_for`, `max_attempts` are unchanged (tests and the
single-policy path depend on them).

### 2. `CompositeRetryPolicy` (new — `executor/composite_retry_policy.rb`, pure)

```ruby
class CompositeRetryPolicy
  attr_reader :policies

  def initialize(policies)
    @policies = Array(policies)
    raise ArgumentError, "composite retry policy needs at least one policy" if @policies.empty?
  end

  # First sub-policy whose retry_on matches the error, or nil.
  def policy_for(error)
    @policies.find { |p| p.matches?(error) }
  end

  # Routes on the *live* error, yields the matched policy's index so the caller
  # can increment and return that policy's running count, then delegates the
  # decision to the matched sub-policy.
  def retry_backoff(error, attempts:)
    idx = @policies.index { |p| p.matches?(error) }
    return nil if idx.nil?

    sub   = @policies[idx]
    count = block_given? ? yield(idx) : attempts
    sub.retryable?(error, count) ? sub.backoff_for(count) : nil
  end

  # Coarsest bound, for the workflow-level safety-net guard in `perform`.
  # nil if any sub-policy is unbounded.
  def max_attempts
    caps = @policies.map(&:max_attempts)
    caps.include?(nil) ? nil : caps.max
  end
end
```

Routing is by `matches?`, which is `is_a?`-based, so a subclass of a `retry_on`
class routes to the right policy. The returned **index** — not the error class —
is the counter key, so subclasses share the budget of the policy they routed to,
exactly as intended.

### 3. Executor wiring

- **`coerce_policy(value)`** — `Array` → `RetryPolicy.compose(*value)`; a
  `RetryPolicy` or `CompositeRetryPolicy` passes through; `nil` → `nil`. Applied
  in `step_retry_policy` and `wait_retry_policy`, and to the class DSL.

- **Class DSL** `retry_policy(*policies, **opts)` — positional policies →
  `RetryPolicy.compose(*policies)` stored as `default_retry_policy`; kwargs only →
  `RetryPolicy.new(**opts)` (unchanged). Mixing both raises `ArgumentError`.

- **Per-error counter, step sites** — one helper, incrementing the matched
  policy's slot in the log metadata and returning the new count:

  ```ruby
  RETRY_COUNTS_KEY = "retry_counts"

  def bump_retry_count!(log, policy_index)
    meta   = log.metadata || {}
    counts = meta[RETRY_COUNTS_KEY] || {}
    key    = policy_index.to_s
    counts[key] = counts[key].to_i + 1
    meta[RETRY_COUNTS_KEY] = counts
    log.update!(metadata: meta)   # explicit reassign so the JSON column is marked dirty
    counts[key]
  end
  ```

- **Per-error counter, workflow level** — `perform` gains `retry_counts: {}` in
  its signature; the failure path increments the in-memory map and threads it
  through the reschedule, beside `attempt:`. No DB write (mirrors `attempt:`).

- **The four retry sites** change from the `retryable? … backoff_for` pair to a
  single `retry_backoff` call carrying the site's counter block. A single policy
  ignores the block, so its path is unchanged and writes no `retry_counts`:

  ```ruby
  backoff = policy.retry_backoff(e, attempts: COUNT) { |idx| <bump counter for idx> }
  if backoff
    self.class.set(wait: backoff).perform_later(@workflow.key, *site_args)
    halt_execution!
  else
    # site-specific terminal action
  end
  ```

  Per-site `COUNT` / counter store / terminal action:

  | Site | `COUNT` (single-policy) | Composite counter store | Terminal action |
  |---|---|---|---|
  | `perform` (workflow) | `attempt + 1` | job-args `retry_counts` (rescheduled with `attempt: attempts_made, retry_counts:`) | `fail_workflow!(error_log)` |
  | `durably_execute` | `execution_log.attempts` | `execution_log.metadata` | mark failed, raise `ExecutionFailedError` |
  | `durably_repeat` | `repetition_log.attempts` | `repetition_log.metadata` | `on_error` (`:continue` / `:fail_workflow`) |
  | `wait_until` | `execution_log.attempts` | `execution_log.metadata` | mark failed, raise `ExecutionFailedError` |

  `durably_repeat` keys its counter on the per-repetition log, so each repetition
  gets its own independent per-error budgets.

## Notable properties

- **Per-error backoff escalation.** `backoff_for(count)` uses the per-error count
  as the exponent, so each error type's backoff escalates on its own schedule.
- **No class-string matching at decision time.** Subclass resolution is a single
  `is_a?` on the live error during routing; the counter is keyed by policy index.
- **`wait_until` still does not inherit the class default.** A per-call array is
  coerced normally; the class-level composite default does not leak in.
- **Workflow-level safety net.** `perform`'s early guard
  (`policy.max_attempts && attempt >= policy.max_attempts`) keeps working because
  `CompositeRetryPolicy#max_attempts` returns the coarsest bound — a safe
  over-estimate that never kills a workflow prematurely.
- **Ordering matters.** Specific policies first, catch-all (`retry_on: nil`) last;
  without a catch-all, an unmatched error fails fast. (Documented footgun.)
- **Mid-flight reorder caveat.** Counts are keyed by policy index, so reordering a
  composite's policies while a long-running workflow is in flight can misattribute
  in-progress counts. Reordering retry config mid-workflow is ambiguous under any
  scheme; documented as a known edge.

## Testing

**Unit — `CompositeRetryPolicy`**
- routing: first match wins; specific-before-catch-all
- catch-all (`retry_on: nil`) matches anything; `retry_on: []` matches nothing
- subclass of a `retry_on` class routes to that policy (and yields its index)
- no match → `retry_backoff` returns `nil`
- `retry_backoff` yields the matched policy's index and uses the yielded count for
  both the cap check and the backoff exponent
- `max_attempts` = coarsest bound; `nil` if any sub-policy unbounded
- empty policy list raises `ArgumentError`

**Unit — `RetryPolicy` additions**
- `matches?` semantics for `nil` / `[]` / class list incl. subclasses
- `retry_backoff` (plain) ignores the block, returns `nil` past the cap
- `RetryPolicy.compose` builds a `CompositeRetryPolicy`

**Unit — `bump_retry_count!`**
- increments the right index slot; independent slots accumulate independently
- reassigns `metadata` so the JSON column persists across reload
- `nil`/absent `metadata` initializes cleanly

**Integration**
- a step raising different error types accumulates independent per-error budgets
  and per-error backoff; fail-fast policy (`max_attempts: 1`) stops immediately;
  subclass of a `retry_on` class draws from the parent policy's budget
- regression: a single `RetryPolicy` (per-call, class default, built-in) behaves
  identically to today and writes no `retry_counts`
- array passed to `retry_policy:` is coerced to a composite
- workflow-level composite default routes correctly, threads `retry_counts`
  through reschedules, and the `perform` safety-net guard honors the coarse
  `max_attempts`
