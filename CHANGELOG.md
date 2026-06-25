## [Unreleased]

### Added

- `ChronoForge::Executor::RetryPolicy` — a single, unified retry abstraction (attempt cap + exponential-with-jitter backoff + error-class predicate) used by every retry site: workflow-level uncaught errors, `durably_execute`, `durably_repeat`, and `wait_until` condition errors. Replaces the three previously-independent retry systems and two backoff algorithms.
- Class-level `retry_policy` DSL to set a workflow's default retry policy, plus a per-call `retry_policy:` keyword on `durably_execute`, `durably_repeat`, and `wait_until`. Resolution is per-call → class default → per-site built-in. `wait_until` deliberately does not inherit the class default (so a class-wide "retry everything" can't silently retry condition-evaluation bugs).
- **Composite retry policies** — pass an ordered array of `RetryPolicy` objects (per-call, or to the class-level `retry_policy` DSL as positional args) to give each error type its own independent attempt budget and backoff. The first policy whose `retry_on` matches the raised error wins (subclasses route to the policy that lists their ancestor; a trailing `retry_on: nil` is a catch-all; an unmatched error fails fast). Per-error counts are keyed by each policy's declared errors (`RetryPolicy#budget_key`) and persisted in execution-log metadata (steps) or the job args (workflow-level), so budgets are stable across replays and policy reordering. `RetryPolicy.compose(*policies)` builds one explicitly.

### Changed

- **BREAKING:** `durably_execute` and `durably_repeat` no longer accept `max_attempts:`; `wait_until` no longer accepts `retry_on:`. All three now take `retry_policy:` (a `RetryPolicy`). Migrate `max_attempts: N` → `retry_policy: RetryPolicy.new(max_attempts: N)` and `retry_on: [...]` → `retry_policy: RetryPolicy.new(retry_on: [...])`.
- **BREAKING:** backoff is now exponential with jitter everywhere (previously the workflow level used a fixed array declared as `[1s,5s,30s,2m,10m]` — though the `should_retry? < 3` bug meant only its first three entries `[1s,5s,30s]` were ever reached — and steps used `2**n` capped at 32s). Workflow-level retries default to 10 attempts with a tolerant window of up to ~8.5 min (≈4 min typical with jitter; cap 600s) — wide enough to ride out a transient infra blip (DB failover, deploy restart) on an uncaught `perform` error, since each such retry replays the whole workflow. A *permanently* failing workflow is now retried 10 times before reaching `failed` (vs the previous effective 4). Note this path covers only uncaught errors in `perform`; a step exhausting its own retries stalls the workflow instead.

### Fixed

- Workflow-level retry no longer has a contradictory cap (`should_retry?` stopped at 3 while `RetryStrategy.max_attempts` was 5, making the array's `2m`/`10m` entries unreachable). The single `RetryPolicy` is now the sole decider.
- Removed the dead `retry_method:` argument that `durably_execute` passed on reschedule but `perform` never bound.

## [0.9.0] - 2026-06-03

### Added

- `ChronoForge::Cleanup` and `ChronoForge::CleanupJob` — a schedulable, batched cleanup that deletes old terminal (completed/failed) workflows and their logs, and (opt-in) prunes the unbounded repetition logs that long-lived `durably_repeat` tasks accumulate. Repetition pruning is frontier-safe: only terminal repetitions scheduled strictly before the coordination log's `last_execution_at` are removed, so catch-up is never disrupted. Retention is configurable per terminal state (`completed_older_than` / `failed_older_than`).
- `chrono_forge:upgrade` generator that installs additive migrations existing apps are missing (idempotent — re-running either generator skips migrations that already exist).
- Composite `[state, completed_at]` index on `chrono_forge_workflows` (separate, strong_migrations-safe migration: built `CONCURRENTLY` on PostgreSQL, `if_not_exists`) to keep monitoring and cleanup scans efficient.
- Validation of user-supplied step names: a name/method/condition containing the reserved `$` separator now raises `ChronoForge::Executor::InvalidStepName`.
- `step_name` and `attempt` columns on `chrono_forge_error_logs` (additive migration), populated by error tracking so each error is attributable to the step and attempt it came from and can be ordered/correlated when tailing a workflow.
- Record-level re-execution: `ChronoForge::Workflow#retry_now` / `#retry_later` (plus `#retryable?`), so a failed/stalled workflow can be re-run straight from its record (e.g. `ChronoForge::Workflow.failed.find_each(&:retry_later)`) without constantizing the job class or re-passing the key. `retry_later` validates retryability up front and raises `WorkflowNotRetryableError` immediately instead of enqueuing a job that would fail in the worker.

### Changed

- **Performance:** execution-log and workflow lookups are now SELECT-first instead of INSERT-first, eliminating an `INSERT`-that-fails-on-the-unique-index (plus a burned sequence value) for every already-completed step on every replay.
- **Performance:** `LockStrategy.release_lock` reads only the lock owner column instead of reloading the full workflow row (which dragged the large JSON `context`/`kwargs`/`options` into memory on every resume).
- **Performance:** workflow completion/failure persist their execution log in a single `UPDATE` instead of two.
- **Performance:** `Context` deep-copies values via `as_json` instead of a `JSON.parse(JSON.generate(...))` round-trip.
- Error-log context snapshots are now bounded: all keys are kept, but once a 64 KB total budget is reached the remaining values are replaced with an `<<omitted>>` marker, so repeated error logging no longer duplicates large context blobs.
- Workflow retention is measured from when a workflow became terminal (`completed_at` for completed, `updated_at` for failed), not from `created_at` — long-running workflows that only just finished are retained for the full window.

### Breaking

- The per-value `Context` size limit is reduced from 64 KB to **16 KB** and is now measured in **bytes** (previously characters, and `String`-only). `Hash` and `Array` values are now size-validated too. Context is intended for small working state; store large payloads elsewhere and keep a reference. Existing workflows that *write* values larger than 16 KB will raise `ChronoForge::Executor::Context::ValidationError`; already-stored values are unaffected when read.

### Fixed

- A failed step no longer logs its terminal failure twice. Previously the step logged the underlying error and `perform` re-logged the `ExecutionFailedError` control-flow wrapper, producing a duplicate row. The wrapper is no longer logged; `wait_until` timeouts (which had no step-level log) are now logged at the step instead.

### Removed

- Dead `serialize :metadata` declaration on `ChronoForge::Workflow` (the table has no `metadata` column).

### Upgrading

```bash
rails generate chrono_forge:upgrade
rails db:migrate
```

## [0.1.0] - 2024-12-21

- Initial release
