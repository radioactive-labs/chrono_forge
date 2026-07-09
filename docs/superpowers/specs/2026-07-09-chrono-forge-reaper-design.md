# Design: Stalled-Workflow Reaper for ChronoForge

**Date:** 2026-07-09
**Gem:** `chrono_forge` (with `chrono_forge-dashboard`)
**Status:** Approved for planning

## Problem

A workflow that is mid-pass when its worker is **hard-killed** (SIGKILL: deploy/rollout,
OOM, node eviction, SolidQueue heartbeat prune) is stranded permanently in `state: running`
with a stale lock, and nothing ever resumes it.

The mechanism, confirmed against the code:

- `Executor#perform` releases the lock and publishes the resume continuation in its `ensure`
  block (`lib/chrono_forge/executor.rb:178-197`): `release_lock` first, then
  `flush_continuation!`.
- `enqueue_continuation` (`executor.rb:369-371`) only records `@continuation` in memory;
  `flush_continuation!` (`executor.rb:376-382`) is what actually enqueues the ActiveJob.
- On SIGKILL, Ruby's `ensure` does not run. So (1) `release_lock` never runs — the row stays
  `state: running` with a past `locked_at`; and (2) `flush_continuation!` never runs — no job
  is scheduled to resume the workflow.

The workflow is fully *resumable* — `Workflow#executable?` is `idle? || running?`
(`workflow.rb:48-50`) and `LockStrategy.acquire_lock` steals any lock older than
`max_duration` (10 min) (`lock_strategy.rb:17-21`) — but nothing re-enqueues it. Existing
recovery mechanisms do not cover this:

- **`BranchMergeJob` rekick** (`branch_merge_job.rb:232-273`) only re-enqueues children that
  are `state: idle, started_at: nil` (never-started dropped dispatches). A child hard-killed
  **mid-pass** is `state: running` with `started_at` set — explicitly excluded (see the
  comment at `branch_merge_job.rb:226-231`). So branch children have the identical gap.
- **Workflow-level retry** rides on the same process that must survive to its `ensure`; a
  killed process never reaches it.
- **`retry_now`/`retry_later`** require `retryable?` (`stalled? || failed?`,
  `workflow.rb:53-55`); a stranded workflow is `running`, so they refuse it.
- **Dashboard "Force unlock"** clears the lock but enqueues nothing.

Real-world impact (reported): 735 workflows stranded over ~8.5 months in one production app,
still accruing ~8/day.

## Solution Overview

Add a reconciliation entry point, `ChronoForge::Workflow.reap_stalled`, that finds workflows
stuck in `running` past a safety threshold and re-enqueues them. Re-enqueue is safe:
`acquire_lock` steals the stale lock and completed durable steps replay as no-ops.

### Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Shipping | **Class method only** | No Railtie/rake task/self-scheduling job. Host apps call it from their own cron/recurring job. Smallest surface; no new gem infrastructure. |
| Scope | **All stranded `running` workflows** (top-level AND branch children) | Strictly more correct — rekick misses mid-pass-killed children. Re-enqueue of a child directly is the proven-safe pattern rekick already uses. |
| Threshold | **Config + per-call override** | `ChronoForge.config.reap_stale_after` (default `30.minutes`), overridable via `stale_after:` arg. Parity with the existing `branch_merge_queue` config. |
| Deliverable | **Code + tests + docs** | Implementation, tests (incl. simulated hard-kill strand), and docs covering the reaper + step-idempotency expectations. |

## Component

`ChronoForge::Workflow.reap_stalled` — a class method on the AR model. It only queries and
re-enqueues; it holds no lock and performs no replay itself (the re-enqueued job does the
replay, under the normal lock protocol).

```ruby
# ChronoForge::Workflow
def self.reap_stalled(stale_after: ChronoForge.config.reap_stale_after)
  reaped = 0
  where(state: states[:running])
    .where("locked_at < ?", stale_after.ago)
    .find_each do |wf|
      wf.job_klass.perform_later(wf.key, **wf.kwargs.symbolize_keys)
      reaped += 1
    rescue => e
      Rails.logger.error { "ChronoForge reap failed for workflow(#{wf.key}): #{e.class}: #{e.message}" }
    end
  Rails.logger.info { "ChronoForge reaped #{reaped} stalled workflow(s)" } if reaped.positive?
  reaped
end
```

Design points:

- **Target = `running` + stale `locked_at`.** The strand happens precisely because the
  `ensure` never ran, so `release_lock` never flipped the row off `running`. A `NULL locked_at`
  cannot match `locked_at < ?` and is naturally excluded (an anomalous running-without-lock row
  is not our target).
- **Sweeps children too.** No `parent_execution_log_id` filter. A re-enqueued child runs,
  replays, completes, and updates its `BranchProbe` state so the parent's merge poller observes
  completion.
- **Re-enqueue via the public guarded `perform_later`.** `wf.kwargs` is a JSON column (string
  keys); `.symbolize_keys` for `**`, matching `setup_workflow!` and `rekick_dropped_jobs`. The
  guard rejects `RESERVED_KWARGS`, which stored user kwargs never contain. Fresh `attempt: 0`
  — a full workflow-retry budget, exactly like a normal resume.
- **Per-row rescue** so one bad row (e.g. cross-version kwarg drift tripping the enqueue guard)
  never aborts the sweep — mirrors `rekick_dropped_jobs` (`branch_merge_job.rb:265-270`).
- **Returns the reaped count** for cron visibility; logs via `Rails.logger` block syntax.

## Configuration

`max_duration` (previously a hardcoded `10.minutes` in the executor) becomes a config value,
and `reap_stale_after` **derives from it** so the "reap threshold must exceed the lock-steal
threshold" invariant is automatic rather than documented-and-hoped.

Add to `ChronoForge::Configuration`:

```ruby
# How long a single pass may hold its lock before it's stealable (feeds
# LockStrategy.acquire_lock via the executor's #max_duration). Default 10 minutes.
attr_accessor :max_duration

# Age past which a :running workflow is considered stranded and re-enqueued by
# Workflow.reap_stalled. Defaults to 3x max_duration (30 min out of the box) so it always
# clears the lock-steal threshold; an explicit value overrides the derived default.
def reap_stale_after
  @reap_stale_after || max_duration * 3
end
attr_writer :reap_stale_after

# in #initialize:
@max_duration = 10.minutes
@reap_stale_after = nil
```

The executor's `#max_duration` now reads `ChronoForge.config.max_duration` instead of
returning a literal. Deriving `reap_stale_after` from `max_duration` means raising one raises
the other, so the reaper can never be configured below the lock-steal threshold by accident.

## Idempotency & Safety (documented behavior)

- **Concurrency-safe.** Overlapping cron runs, or a re-enqueue landing while the old stale
  lock still shows, at worst enqueue a duplicate job — the second loses the `acquire_lock`
  race and no-ops via `ConcurrentExecutionError`. Mild, harmless churn. Recommend a cron
  interval comfortably longer than a typical resume pass.
- **Step idempotency.** Reaping replays the interrupted pass. A `durably_execute` step only
  short-circuits when `completed`, so a step whose side effect committed but whose log never
  reached `completed` will re-run on replay. Steps with external side effects must be
  idempotent (natural/unique key + `create_or_find_by`/rescue). Documented alongside
  `wait`/`durably_execute`.

## Non-Goals (conscious boundaries)

- **Dropped `BranchMergeJob` poller → parent stranded `idle`.** A parent parked on a merge
  whose poller was hard-killed sits `idle`, not `running`, so this reaper won't catch it. A
  distinct failure mode; the code already hints (`branch_merge_job.rb:181-184`) that a
  "`next_poll_at` far in the past with work still pending" detector is the right fix. Out of
  scope here.
- **Micro-window between `release_lock` and `flush_continuation!`.** A process dying between
  those two statements yields `idle` + no continuation. Theoretically possible, not seen in the
  reported evidence (all strands were `running`), not covered.

## Testing

- **Query selection (unit):** selects only `running` + stale-lock rows; excludes
  fresh-lock `running`, `idle`, `completed`, `failed`, `stalled`, and `NULL locked_at`.
- **Strand-and-recover (behavioral):** create a workflow, force it into `running` with an old
  `locked_at` and no scheduled resume job (simulating the hard-kill), run `reap_stalled`,
  assert a job is enqueued and that draining the queue resumes and completes the workflow.
  Cover both a top-level workflow and a branch child.
- **Per-row rescue:** a row that raises on re-enqueue does not abort the sweep; the returned
  count reflects only successful re-enqueues.
- **Config:** default `reap_stale_after` honored; per-call `stale_after:` override honored.

## Documentation

- Document `Workflow.reap_stalled` and the recommended cron wiring (host-owned; no shipped
  task), including the `reap_stale_after > max_duration` constraint.
- Document the step-idempotency expectation alongside `wait`/`durably_execute`.

## Alternatives Considered

- **Railtie + `chrono_forge:reap` rake task** (angarium `angarium:reap` parity) — rejected;
  heavier, would add the gem's first Railtie.
- **Self-scheduling reaper ActiveJob** — rejected; adds an always-on job and scheduling
  assumptions the host may not want.
- **Top-level-only sweep** (`parent_execution_log_id IS NULL`) — rejected; leaves
  mid-pass-killed branch children stranded, which rekick does not recover.
