## [Unreleased]

## [0.9.1] - 2026-06-25

### Fixed

- `LockStrategy.acquire_lock` no longer raises a `NameError` (`undefined local variable or method 'key'`) on lock contention. The concurrent-execution branch referenced an undefined `key` while building its error message, so the intended, benign `ConcurrentExecutionError` ("currently being executed by job X") was masked by a hard `NameError` on every duplicate/racing execution of the same workflow. It now surfaces the real `ConcurrentExecutionError`.
- Corrected `#{self.class}` → `#{name}` in `LockStrategy`'s lock log/error messages. These are singleton methods (`class << self`), so `self` is already the class and `self.class` rendered the literal string `Class`; messages now name the strategy class.

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
