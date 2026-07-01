# ChronoForge fan-out scale test

_Run 2026-06-28 on a local Mac (11 cores)._

Two things were measured here:

1. **Correctness at scale** — does a fan-out converge, lose nothing, and stay in
   constant memory up to **500,000 children**?
2. **Throughput** — what is the steady-state ceiling, where is it, and how much
   does an experimental **commit-consolidation** change move it (matched
   baseline-vs-consolidation pairs at 20k / 50k / 100k)?

## What was tested

A parent workflow that fans out **N child workflows** via `branch` + `spawn_each`
(a `Range` source → constant-memory batched `insert_all`, joined inline with
`automerge`). Each child is one trivial `durably_execute`.

```ruby
class ScaleFanout < ActiveJob::Base
  prepend ChronoForge::Executor
  def perform(count:)
    branch :fanout, automerge: true do
      spawn_each :child, (1..count) { |i| [ScaleChild, {n: i}] }
    end
  end
end
```

All runs were on **Solid Queue + Postgres 13 (Docker)** against a dev DB. Workers
ran on an **isolated `scale` queue** (`BranchMergeJob`
re-routed to the same queue so it never competed with real jobs).

| Parameter | Value |
|---|---|
| Job backend | Solid Queue, isolated `scale` queue |
| Database | Postgres 13 (Docker), `max_connections` 100, `shared_buffers` 128 MB |
| Worker concurrency | 5 processes × 4 threads (= 20 slots) |
| DB connection pool | `DB_POOL=10` per process |
| Worker polling interval | 0.1 s |
| Dispatcher | default Solid Queue dispatcher |
| Child workload | one trivial `durably_execute` (no real I/O) |

---

## Part 1 — Correctness (500k)

| N | Wall clock | Throughput | Completed | Outcome |
|---|-----------|------------|-----------|---------|
| 20,000 | 88.3s | 226/s | 20,000 / 20,000 | ✓ merged |
| 50,000 | 215.5s | 232/s | 50,000 / 50,000 | ✓ merged |
| 100,000 | 443.2s | 226/s | 100,000 / 100,000 | ✓ merged |
| **500,000** | **2,497s (~41.6 min)** | **200/s** | **500,000 / 500,000** | **✓ merged** |

**Flawless at every scale.** Every child completed and every parent converged to
`completed`. Streaming dispatch held constant memory; `BranchMergeJob` polled to
convergence; the parent's replay correctly **skipped the sealed branch** (no
re-dispatch). Zero failures, zero lost children, no memory wall.

Throughput held **rock-steady at ~200–230/s from 20k through 500k** — no
degradation as the tables grew. The path has a **stable steady-state ceiling**.

---

## Part 2 — Benchmark: baseline vs commit-consolidation

**Baseline** is the current released engine (v0.10). **Consolidation** is the
unreleased patch targeted for **v0.12** that cuts per-child write cost without
changing behaviour. It (a) folds `started_at` into the lock-acquire
transaction, (b) collapses `complete_workflow!`'s three separate commits — marker
INSERT + `workflow.completed!` UPDATE + marker UPDATE — into one transaction, and
(c) flattens the INSERT-then-UPDATE pairs in the step / completion / failure /
`continue_if` / `durably_repeat` paths into single INSERTs (the row is born in its
terminal/attempted state). It deliberately does **not** merge `context.save!` +
`release_lock` — that split is load-bearing (the lock must release even if the
save raises). See `docs/design/per-child-commit-overhead.md` for the full set.

Matched pairs, isolated worker (5 procs × 4 threads), `DB_POOL=10`, single
Postgres, ~170k-row backdrop held constant across all six runs. Throughput is
measured over the child window: `N / (max(completed_at) − min(created_at))`.

### Throughput

| Run | N | Fan-out (dispatch) | Dispatch rate | **Exec throughput** |
|------|------:|------:|------:|------:|
| baseline 20k | 20,000 | 9.6s | 2,093/s | **226/s** |
| cons 20k | 20,000 | 7.8s | 2,561/s | **293/s** (+30%) |
| baseline 50k | 50,000 | 30.4s | 1,647/s | **232/s** |
| cons 50k | 50,000 | 17.2s | 2,905/s | **279/s** (+20%) |
| baseline 100k | 100,000 | 63.7s | 1,570/s | **226/s** |
| cons 100k | 100,000 | 53.0s | 1,886/s | **275/s** (+22%) |

### Per-child execution time — `completed_at − started_at` (seconds)

| Run | avg | p50 | p95 | p99 | max |
|------|----:|----:|----:|----:|----:|
| baseline 20k | 0.042 | 0.035 | 0.074 | 0.137 | 0.544 |
| cons 20k | 0.020 | 0.018 | 0.030 | 0.070 | 0.560 |
| baseline 50k | 0.041 | 0.035 | 0.065 | 0.138 | 0.933 |
| cons 50k | 0.022 | 0.019 | 0.035 | 0.074 | 0.812 |
| baseline 100k | 0.042 | 0.036 | 0.072 | 0.148 | 0.911 |
| cons 100k | 0.022 | 0.019 | 0.038 | 0.079 | 0.578 |

### Fan-out (spawn) time — child `created_at` span

How long the parent's `spawn_each` took to enqueue the whole set
(`max(created_at) − min(created_at)` over the children):

| Children | baseline | consolidation |
|---:|---:|---:|
| 20k | 9.6s (2,093/s) | 7.8s (2,561/s) |
| 50k | 30.4s (1,647/s) | 17.2s (2,905/s) |
| 100k | 63.7s (1,570/s) | 53.0s (1,886/s) |

Spawning 100k children takes ~64s on baseline, ~53s consolidated — roughly
**0.5–0.6 ms of parent time per child**. The spawn rate **degrades as N grows**
on baseline (2,093 → 1,570/s) because the parent inserts child rows into the same
Postgres that's simultaneously draining the early children. Consolidation lightens
the children's commit load, freeing fsync budget for the parent's inserts, so its
spawn rate holds up far better.

---

## Throughput analysis — a *flat* ceiling, set by fsync

The ceiling is **single-Postgres commit/`fsync` throughput**, not worker count:

- Throughput is **flat (~200–230/s) from 20k to 500k** — it neither degrades as
  tables grow nor rises with more work in flight against 20 worker slots.
- Halving per-child execution time (consolidation, below) lifts aggregate
  throughput only **~25%** — so the bottleneck is shared write infrastructure, not
  per-child work or worker count.
- **Not** connection-bound (51 / 100 connections used), **not** memory-bound.

Each trivial baseline child costs ~**10 primary-DB commits + ~2 Solid Queue
commits** (the `complete_workflow!` entry below is itself three separate commits):

```
setup started_at · acquire_lock · step INSERT · step attempt-update ·
step completed-update · complete_workflow! (×3) · context.save! · release_lock   (+ SQ claim/finish)
```

≈ 200 children/s × ~10 commits ≈ **~2,000 fsyncs/s** — the wall.

**Commit consolidation confirms the diagnosis.** Folding `started_at` into the
lock-acquire txn, collapsing `complete_workflow!`'s three commits into one, and
baking each log's first write into its INSERT **halves per-child execution time**
(p50 ~35 ms → ~19 ms, −46%; avg −49%) and is **flat across 20k→100k**. Yet
aggregate throughput rises only **+20–30%**, not 2×: once the
child's own commits are cheaper, the **Solid Queue claim/finish cycle** and the
shared single-Postgres fsync budget dominate the per-slot time. Halving one of
several serial commits can't double the whole pipeline.

## Queue wait is backlog math, not a latency regression

Per-child **queue wait** (`started_at − created_at`) scales ~linearly with N:

| Run | avg | p50 | p95 | max |
|------|----:|----:|----:|----:|
| baseline 20k | 40.6 | 42.9 | 75.3 | 78.7 |
| cons 20k | 30.3 | 29.3 | 57.4 | 60.4 |
| baseline 50k | 93.7 | 95.6 | 173.0 | 185.1 |
| cons 50k | 80.7 | 80.3 | 154.4 | 161.9 |
| baseline 100k | 191.6 | 194.9 | 357.8 | 379.5 |
| cons 100k | 151.7 | 147.5 | 291.1 | 310.9 |

This is **not** a per-job slowdown. The entire set is enqueued in seconds but
drains at ~225–290/s, so a child's wait is just its **position in the backlog ÷
throughput**. The last of 100k children waits ~100,000 / ~270 ≈ ~6 min by
arithmetic, regardless of how fast any individual child runs. Consolidation
shrinks the wait proportionally (100k: 192s → 152s) because it lifts throughput —
the lever for queue wait is throughput, not per-child execution time.

## Dashboard at 500k

The dashboard's scale-aware design held up live: capped `5000+` counts (no
`COUNT(*)` over 500k), keyset pagination, blocked-first triage — instant render
throughout the run.

## Poller behavior

`BranchMergeJob` cadence is driven by **estimated time-to-drain** (from the prior
poll's uncapped pending count), not backlog size. For a 500k fan-out draining at
~200/s this is flat `max_interval` (5 min) polling through the long middle, then a
smooth ramp over the final minutes, tightening to `min_interval` (~5s) for the
last few thousand children — so the parent is woken within ~5s of the last child
finishing rather than up to a full `max_interval` late. ~15 cheap polls across the
run, one branch-scoped index count each (`[parent_execution_log_id, state]`); no
new indexes. When nothing completes in an interval the fallback is motion-aware: a
child still running holds the responsive floor (so a slow or single-child branch is
never woken late), a dispatched-but-unpicked straggler backs off exponentially, and
a fully blocked/waiting branch decays to `max_interval` instead of spinning.

Rekick of dropped children is **gated on the never-started count
delta**: if that count fell since the last poll, workers are consuming the branch's
queue, so deeply-queued-but-healthy children are left alone. It deliberately does
NOT use total pending — a `wait_until` child resuming would drop pending without
any never-started child moving, masking a genuinely-dropped child behind staggered
waits. Only a branch whose never-started count has gone flat has its stale
never-started children rekicked, and a `touch` on each rekick debounces it to at
most once per `REKICK_AFTER`. Rekick counts are stamped on the branch-log metadata
for the dashboard.

### ⚠️ Poller queue placement (a trap)

`merge_branches` enqueues `BranchMergeJob` **after** it dispatches the branch's
children, so the poller **must not run on the same queue as a large fan-out's
children**. If it does, it is enqueued behind the entire backlog and starved: it
gets a worker slot only near the end, polls **once** at `pending≈0` with no prior
sample (`rate 0`), and backs off to `max_interval`. The consequences are twofold
and both defeat the point of the ETA cadence:

- the parent's convergence **lags by up to `max_interval` (~5 min)** after the last
  child finishes (all children `completed`, parent still `idle`); and
- the dashboard's **live throughput/ETA never renders** — the poller never took a
  mid-drain sample, so `rate` stays 0.

Give the poller a **dedicated, un-starved queue** so it polls throughout the drain
(then ETA engages and convergence is tight) via the first-class setting:

```ruby
ChronoForge.configure { |c| c.branch_merge_queue = :chrono_forge_pollers }
```

(and run a worker on that queue). It defaults to `:default`, which is fine when
fan-outs run on their own queues. For these runs that queue is `:scale_poller`
(see `config/scale_queue.yml`). This bit us live-driving 20k/100k — the first pass
had the poller on `:scale` and every parent hung `idle` for 5 min.

## Environment caveats

- Local Docker **Postgres 13**, default `shared_buffers` 128 MB, single disk,
  `max_connections` 100. Absolute numbers are this-laptop-specific; tuned/larger
  production infra changes them.
- Part 1's 20k–100k rows are the **same clean baseline runs** as Part 2 (matched
  pairs at a fixed ~170k-row backdrop). The **500k** row is the original
  single-growing-table run, so its absolute throughput isn't strictly comparable
  to the others — but it lands in the same ~200/s band.
- A child here is a **trivial** `durably_execute`; real children doing actual work
  shift the bottleneck away from the engine's own commits.
