# BranchMergeJob: ETA poll cadence, drain-aware rekick, configurable poller queue

_Implementation record. Started from the two defects below; the final shape was
driven by three review rounds and a live 20k/100k/500k drive, so this documents
what shipped, not a pre-implementation plan._

## Problem

`ChronoForge::BranchMergeJob` is the lightweight poller that joins a fan-out's
branches: each pass it counts a branch's incomplete children, wakes the parent
when all are sealed and complete, otherwise re-arms itself. Two defects, plus a
deployment trap surfaced by the live drive:

1. **Rekick re-enqueued healthy children.** `rekick_dropped_jobs` re-dispatched any
   child that was `idle`, `started_at: nil`, and `updated_at < REKICK_AFTER.ago` —
   which also matches a healthy child merely waiting deep in a draining backlog
   (queue wait exceeds `REKICK_AFTER` at N ≥ 100k). And because `perform_later`
   never touched the row, a rekicked-but-unpicked child stayed stale and was
   **re-rekicked every poll**, piling up duplicates.

2. **Cadence overshoot.** The delay was `(progressing × FACTOR).clamp(min, max)`
   with `progressing` a count capped at `CAP = 5000`, so it saturated to
   `max_interval` while any large backlog existed — polling *slowest* exactly when
   a fast-draining backlog was about to finish. A 20k fan-out drains in ~88s but
   the parent wasn't woken until ~310s; 500k sealed up to 5 min late.

3. **Poller starvation (deploy trap).** `merge_branches` enqueues the poller *after*
   dispatching the branch's children, so on a queue those children saturate it is
   starved behind the whole backlog — it polls once, at pending≈0, and backs off,
   so the parent converges up to `max_interval` late and no throughput is recorded.
   The only lever was monkey-patching `BranchMergeJob.queue_as` in the host app,
   which a dev code-reload can silently reset.

## Solution overview

- **Cadence** is driven by **estimated time-to-drain**, measured from the branch's
  own completion rate — so the parent is woken within ~`min_interval` of the last
  child finishing. When an interval sees no completion, the fallback is
  **motion-aware** so a slow-but-healthy child isn't woken late.
- **Rekick** is gated on the **never-started count delta** — the true
  "workers are pulling this branch's queue" signal — and **debounced** with
  `child.touch`, so healthy deep-queued children are never rekicked and a dropped
  child is redelivered at most once per `REKICK_AFTER`.
- The poller's **queue is a first-class config** (`branch_merge_queue`), since its
  placement is our concern, not the user's.
- The measured **rate + ETA are persisted** each poll and surfaced **live on the
  dashboard**, which now **auto-refreshes on every page**.

---

## Cadence — `reschedule_delay(pending, rate, motion, prev_delay, min, max)`

`lib/chrono_forge/branch_merge_job.rb`

```ruby
def reschedule_delay(pending, rate, motion, prev_delay, min_interval, max_interval)
  return (pending / rate * ETA_FRACTION).clamp(min_interval, max_interval) if rate > 0

  case motion
  when :running then min_interval
  when :never_started then prev_delay ? (prev_delay * 2).clamp(min_interval, max_interval) : min_interval
  else max_interval
  end
end
```

- **Draining (`rate > 0`):** poll at `ETA_FRACTION` (0.5) of the projected time-to-
  drain. Because each poll re-estimates against the shrinking remainder, the cadence
  converges geometrically and tightens to `min_interval` at the tail.
- **No completion this interval → `motion`:**
  - `:running` — a live worker is executing a child; it will finish, so **hold the
    floor** (`min_interval`). This is the anti-regression case: backing off would
    wake the parent late for a slow / single-child branch.
  - `:never_started` — the only motion is a queued/rekicked-but-unpicked child that may
    never be picked up → **exponential backoff** from the floor (double `prev_delay`,
    capped at `max`). Catches a quick recovery in seconds; decays instead of spinning.
  - `:none` — nothing can progress (blocked/failed or parked on a wait) →
    `max_interval` backstop.

Inputs, computed in `perform`:

- **`pending`** is the **uncapped** incomplete count (`BranchProbe.incomplete(id)
  .count`), served by the existing `[parent_execution_log_id, state]` index — one
  branch-scoped count per poll (~7 for 20k, ~15 for 500k; a background cost). The
  old `CAP` flattened this to a constant `5000`, which is why the ETA couldn't reuse
  it. `CAP` and `FACTOR` are removed; `ETA_FRACTION` added.
- **`rate`** = `(prev_pending − pending) / elapsed` when the branch drained since its
  prior poll, else `0.0`. Measured per branch (`rate_by_branch`, for the dashboard)
  and aggregated for the ETA. Aggregate `prev_pending` is only trusted when every
  requested branch log is loaded *and* carries a prior sample
  (`logs.size == branch_log_ids.size && prior.all?`), so a partial set can't yield a
  bogus rate.
- **`motion`** is computed **lazily** — only when `rate == 0`, keeping the EXISTS
  probes off the hot drain path: `:running` if any `BranchProbe.running?`, else
  `:never_started` if any branch has a positive never-started count, else `:none`.
- **`prev_delay`** comes from the prior poll's persisted `interval`, driving the
  exponential backoff.

## Rekick — `rekick_dropped_jobs(branch_log_ids, never_started_by_branch, prev_never_started_by_branch)`

```ruby
prev = prev_never_started_by_branch[id]
next [id, 0] if prev && never_started_by_branch[id] < prev   # never-started count fell → workers consuming → in line
# else: scan idle & started_at IS NULL & updated_at < REKICK_AFTER.ago, limit REKICK_BATCH,
#       guarded perform_later, then child.touch on success (debounce), rescue per child.
```

- **Gate on the never-started count delta, not total pending.** A
  `wait_until` child resuming drops total `pending` without any never-started child
  being consumed, so a pending-delta gate would mistake that for "draining" and
  defer recovery of a genuinely-dropped child behind staggered waits. The
  `idle & started_at IS NULL` count falling is the real signal that workers are
  pulling this branch's queue (added `BranchProbe.dispatched`, a countable relation).
- **Cold poll (no prior sample) doesn't gate** — it falls through to the per-child
  staleness filter, which already spares freshly-dispatched children, so a dropped
  child is still recovered on the first poll.
- **`child.touch` on a successful rekick** bumps `updated_at`, so the child leaves
  the staleness window for one `REKICK_AFTER` — redelivered at most once per window,
  killing the re-rekick pile-up. Only on success; a rescued enqueue failure leaves it
  stale to retry next poll.
- Best-effort: a per-child rescue keeps one bad child from sinking the whole poll.

## Persisted poll state — `record_poll!`

Each pass stamps the branch log's `metadata["poll"]` (under `with_lock` + a token
recheck, leaving `spawn_each`'s cursors untouched):

`last_polled_at`, `next_poll_at`, `interval`, `pending`, `dispatched`, `sealed`,
`rate` (children/s, `round(3)` so a very slow but real drain still reads > 0),
`eta_seconds`, `polls`, `rekicked`, `rekick_total`, `last_rekick_at`.

`rate`/`eta_seconds` are **free** — already computed for the cadence, no extra query
— which is what lets the dashboard show live throughput without the aggregate scans
the scale-aware design avoids.

## Configurable poller queue

`lib/chrono_forge/configuration.rb` (the engine's first config object):

```ruby
ChronoForge.configure { |c| c.branch_merge_queue = :chrono_forge_pollers } # default: :default
```

`BranchMergeJob` reads it via `queue_as { ChronoForge.config.branch_merge_queue }`
— resolved **per-enqueue**, so a change takes effect without redefining the job and
can't be silently reset by a code reload (the fragility the live drive exposed). Keep
the poller off a queue saturated by a fan-out's own children.

## Dashboard (`chrono_forge-dashboard`)

- **Live throughput / ETA on in-flight merges.** `BranchesPresenter::Merge` gains
  `:rate` / `:eta_seconds` and `throughput? = merging? && rate.to_f > 0`; the merges
  list renders `<rate>/s` and `ETA <cf_secs>`, both guarded. **Multi-branch merges
  aggregate** — `merge_throughput` sums per-branch `rate` and recomputes the combined
  ETA (`Σpending / Σrate`), rather than showing one branch's figure.
- **Auto-refresh on every page.** The poll region is marked once on the layout's
  `<main>` (the nav + refresh/time controls sit in `<header>`, outside the swap), so
  every page — workflow list *and detail*, analytics, waiting, repetitions —
  refreshes in place, preserving filter text, focus, and scroll. It was previously
  per-page opt-in, which had silently left the detail page (where the gauge lives)
  and several others un-refreshing.

## Files changed

**`chrono_forge`**
- `lib/chrono_forge.rb` — `config` / `configure` / `reset_configuration!`.
- `lib/chrono_forge/configuration.rb` — new; `branch_merge_queue`.
- `lib/chrono_forge/branch_merge_job.rb` — `queue_as` from config; ETA + motion
  cadence; dispatched-delta rekick + `touch`; uncapped `pending`; `record_poll!`
  fields; `superseded?(logs, …)`; removed `CAP`/`FACTOR`, added `ETA_FRACTION`.
- `lib/chrono_forge/branch_probe.rb` — `running?`, `dispatched`/`dispatched?`;
  `incomplete` used uncapped (`progressing` retained, unused by the poller).
- `lib/chrono_forge/executor/methods/merge_branches.rb` — stale cadence comment.
- `test/branch_merge_job_test.rb`, `test/branch_probe_test.rb` — cadence (motion),
  dispatched-delta rekick incl. the waits-drain-pending regression, debounce,
  throughput persistence, configurable queue.
- `docs/fanout-scale-test.md`, `README.md` — cadence, rekick, queue config, the
  poller-queue-placement trap.

**`chrono_forge-dashboard`**
- `branches_presenter.rb` — `Merge` rate/eta + `throughput?` + `merge_throughput`
  aggregate.
- `_branches.html.erb` — throughput/ETA spans (sub-1/s shown to one decimal).
- `layouts/.../application.html.erb` — `data-poll-region` on `<main>`; removed the
  per-page markers.
- `test/branches_test.rb`, `README.md` — aggregation test; docs.

## Validation

Full engine suite **263** tests green; dashboard **106**. Live-driven on Solid Queue
+ Postgres (poller on a dedicated `:scale_poller` queue):

- **20k / 100k** — parents converged; the dashboard showed live `~226/s` + ETA that
  ramped down and vanished on completion.
- **500k** — **500,000 / 500,000** children completed, parent converged, **11**
  poller passes (ETA cadence held throughout, not a single starved poll), and **200**
  children rekicked + recovered after a mid-drain worker restart — the
  rekick/debounce path exercised at scale.

## Review findings resolved

- **#1** — rekick gate moved from total-pending delta to the never-started count
  delta (dropped-child recovery no longer deferred behind resuming waits).
- **#2** — multi-branch merges aggregate rate/ETA in the presenter.
- **#3** — `rate` stored `round(3)` so a sub-1/s drain still renders throughput/ETA.
