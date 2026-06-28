# Per-child commit overhead on large branch fan-out

Status: **implemented and benchmarked**, targeted for **v0.12** (baseline is the
released v0.10). All the consolidations under "Implemented" below have shipped to
the working tree and are validated by matched baseline-vs-consolidation benchmarks
at 20k/50k/100k — see
[`fanout-scale-test.md`](../fanout-scale-test.md): **~−50% per-child execution
time, +20–30% throughput**, flat across scale. The risky `save`+`release` merge was
deliberately left out. Scope: `chrono_forge` core engine. Independent of the dashboard.

## Problem

Branch fan-out throughput tops out at roughly a couple thousand DB commits/sec
on a single Postgres writer. Each child workflow, even a trivial one that runs a
single `durably_execute` to completion in one `perform`, produces a string of
independent transactions. Because every transaction is its own `fsync`, the
workload is commit-bound (fsync-bound), and the number of children you can drain
per second is `~(fsync budget) / (commits per child)`.

For ~8 primary-DB commits per child plus Solid Queue overhead, ~10 workers land
around ~2,000 fsync/s — that's the ceiling. Lowering commits-per-child raises the
ceiling proportionally.

## The actual per-child commit sequence

Traced for a trivial child: one `durably_execute`, runs to completion in a single
`perform`. Each row is one transaction = one commit = one fsync.

| # | Where | Write | Source |
|---|-------|-------|--------|
| 1 | `setup_workflow!` | `update_column(:started_at)` — **branch children only** (parent pre-inserts the row, so the create block never stamps it) | `executor.rb:221` |
| 2 | `LockStrategy.acquire_lock` | `transaction { lock!; update_columns(locked_by, locked_at, state: :running) }` | `executor/lock_strategy.rb:10-33` |
| 3 | `durably_execute` | INSERT execution log (`find_or_create_execution_log!`) | `executor/methods/durably_execute.rb:70` |
| 4 | `durably_execute` | `update!(attempts, last_executed_at)` — *before* the step | `executor/methods/durably_execute.rb:80` |
| 5 | `durably_execute` | `update!(state: :completed)` — *after* the step | `executor/methods/durably_execute.rb:89` |
| 6 | `complete_workflow!` | **three separate commits**: completion-marker INSERT + `workflow.completed!` UPDATE + log `update!` | `executor/methods/workflow_states.rb:50-70` |
| 7 | `ensure` → `context.save!` | `update_column(:context)` | `executor/context.rb:70`, called at `executor.rb:187` |
| 8 | `release_lock` | `update_columns(locked_at: nil, locked_by: nil, …)` | `executor/lock_strategy.rb:53` |
| + | Solid Queue | claim + finish/delete (2 more, in the **queue** DB) | backend |

So ~8 primary-DB commits + ~2 queue commits per child. Empirically (SQLite probe
of a no-step child), step 6 is **three** independent commits, not one — the
completion-marker INSERT, the workflow→`:completed` UPDATE, and the marker UPDATE
each commit separately. That made it the single biggest safe win.

## What's safely reducible (≈⅓, realistically ~8 → ~5)

> Note: this section is the original sketch. It shipped *differently* — see
> "Implemented" below. The real target turned out to be `complete_workflow!`'s own
> three commits (#6), which collapse to one safely; #7+#8 (`context.save!` +
> `release_lock`) were deliberately left split. Net effect is the same ~⅓.

These have no external side effect between them, so collapsing them into one
transaction cannot cause double-execution of anything observable:

- **Collapse the end-of-run trio (#6, #7, #8).** Completion + context save + lock
  release happen back-to-back with nothing external in between. One transaction
  instead of three. Caveat: today `context.save!` and `release_lock` are
  deliberately ordered in an `ensure` so the lock is released (and the
  continuation published) *even if the save raises* — see `executor.rb:178-196`.
  Any consolidation must preserve that "always release the lock, never strand the
  workflow" guarantee. Merging the happy path while keeping the failure path's
  release semantics is the careful part.
- **Fold #1 into #2.** Stamp `started_at` inside the `acquire_lock` transaction
  instead of as its own `update_column`. Saves one commit on branch children.

Net: ~8 → ~5 primary commits ⇒ a proportional throughput bump on a commit-bound
workload. Real and worth doing, but it's ~40%, **not** an order of magnitude.

## What is NOT reducible (it's the point of the engine)

- **The per-step INSERT + "completed" UPDATE (#3, #5) must commit independently
  of other steps.** That committed "completed" marker is exactly what guarantees a
  side-effecting step (charge a card, send a webhook) runs once and is never
  replayed. You cannot batch step-completion commits across steps without risking
  double-execution of external effects. It looks wasteful for a no-op child, but
  the engine cannot assume a step is side-effect-free.
- **Lock acquire (#2) must commit before doing work** so other workers see it.
- **Solid Queue's claim/finish** is backend overhead, outside ChronoForge.

## The real lever for massive fan-out is architectural, not commit-tuning

To run millions of trivial children you change the shape, not shave commits:

- **Bulk / lightweight child mode** for large sets of trivial, idempotent items:
  process N items as one durable unit, or a leaner child path that skips the full
  lock + completion ceremony when a child has no deferral points. Cuts per-item
  commits dramatically, but **trades away per-item isolation and observability** —
  a feature with real trade-offs, not a tweak.
- **Opt-in "transactional workflow" mode**: whole `perform` in one transaction → 1
  commit. Only safe for genuinely side-effect-free workflows.
- **Scale the write tier out** (sharded Postgres) if you need raw commit headroom.

## Implemented

Two consolidations shipped, both behaviour-preserving and covered by tests:

1. **`complete_workflow!` → one transaction** (`workflow_states.rb`). The marker
   INSERT, the workflow→`:completed` UPDATE, and the marker UPDATE now share a
   single `ActiveRecord::Base.transaction`. 3 commits → 1. The failure path
   re-finds/recreates the marker and records `:failed` outside the rolled-back
   transaction, so completion observability is preserved and a resume simply
   retries completion. Test: `WriteConsolidationTest#test_completion_writes_share_a_single_transaction`.
2. **`started_at` folded into `acquire_lock`** (`lock_strategy.rb`). The branch-child
   first-execution `started_at` stamp now rides along the existing lock UPDATE
   (`update_columns`) instead of a standalone `update_column` in `setup_workflow!`.
   1 commit → 0 (absorbed). The poller's "nil started_at = dropped child" contract
   is preserved — it's still stamped on first pickup, just in the same write.
   Tests: `LockStrategyTest#test_acquire_lock_stamps_started_at_*`.

Net for a trivial branch child: roughly 3 fewer commits/fsyncs per child (the
note's safe ~⅓), with no behaviour change.

### Statement flattening (a different axis: round-trips/CPU, not fsyncs)

Within the now-single transactions, two INSERT-then-UPDATE pairs were collapsed to
a single INSERT. This does not cut commits further — it cuts statements (DB
round-trips, parse/plan CPU, a little WAL), so it pays most on round-trip- or
CPU-bound profiles, less on a pure single-writer fsync-bound one.

3. **Completion marker born completed** (`workflow_states.rb`). The marker is
   INSERTed already in `:completed` state (attempts: 1, all timestamps set) instead
   of INSERTed `:started` then UPDATEd. The rare resume-after-failed-completion /
   create-race path still flips an existing marker via UPDATE. Completion is now
   2 statements (marker INSERT + workflow UPDATE), down from 3. Test:
   `WriteConsolidationTest#test_completion_marker_is_born_completed_in_a_single_insert`.
4. **`durably_execute` first attempt recorded in the INSERT** (`durably_execute.rb`).
   A fresh step log is created with `attempts: 1, last_executed_at` baked in, so the
   pre-execution attempt-bump UPDATE is skipped on first run (detected via
   `previously_new_record?`). Retries (existing log) still bump via UPDATE — the
   committed `:completed` write after the side effect is untouched (the once-only
   boundary). Tests: `WriteConsolidationTest#test_first_step_run_records_attempt_in_the_insert`
   and `#test_retry_run_bumps_attempt_with_an_update`.

The same two shapes recur across the engine, so the flattening was applied
everywhere the pattern is safe (a log written twice in one pass, no deferral
between the writes):

5. **`fail_workflow!` born-completed + one transaction** (`workflow_states.rb`).
   Identical to `complete_workflow!`: the workflow→`:failed` transition and the
   (born-completed) failure marker are batched in one transaction, marker written
   terminal in a single INSERT. Test:
   `WriteConsolidationTest#test_failure_marker_is_born_completed_in_a_single_insert`.
6. **`continue_if` first evaluation in the INSERT** (`continue_if.rb`). Same as
   `durably_execute` — a fresh gate bakes `attempts: 1`; only re-evaluations after a
   not-met halt bump via UPDATE. Test:
   `WriteConsolidationTest#test_continue_if_first_run_records_attempt_in_the_insert`.
7. **`durably_repeat` coordination + repetition logs** (`durably_repeat.rb`). Both
   bake the first attempt into their INSERT; later passes/resumes bump via UPDATE.
   Test: `WriteConsolidationTest#test_durably_repeat_first_repetition_records_attempt_in_the_insert`.

The born-completed sites (#3, #5) share one helper, `create_completed_execution_log!`
(`executor.rb`): a single race/replay-safe INSERT in `:completed` state, falling
back to an UPDATE only when the row already exists.

Not flattened: **`merge_branches`** and the **`durably_repeat` fast-forward summary**
create their log in one pass and complete/finalize it in a *later* pass (across a
halt), or merge metadata into a reused row — the two writes are inherently separate,
so there's nothing to collapse. **Waits** (`wait`, `wait_until`) and **branch
coordination** are the same story: they must persist `:started` before halting.

`acquire_lock`'s SELECT…FOR UPDATE + UPDATE was left as a SELECT + UPDATE: a
single conditional UPDATE would flip pessimistic→optimistic locking and complicate
`ensure_executable!` / the contention-error message for one statement — not worth it.

Full suite (236 tests) green; behaviour unchanged.

### Deliberately NOT done: merging `context.save!` + `release_lock`

Tempting (it's the remaining adjacent pair), but the split is load-bearing. The
`ensure` block (`executor.rb:178-196`) guarantees the lock is released — and the
continuation published — *even if `context.save!` raises*, and it publishes the
continuation only after a successful release so a zero-delay same-key continuation
can't lose the acquire race. Wrapping save+release in one transaction would roll
the release back with a failed save and strand the workflow holding its lock.
A correct merge needs a fallback (standalone release on rollback) plus careful
handling of the lost-lock case, and it also changes whether context persists when
this job has lost the lock. That subtlety isn't worth one commit on a safety-
critical path — left as-is intentionally.

## Benchmark outcome

Measured against matched baseline pairs at 20k/50k/100k (single Postgres, 5×4
workers; full data in [`fanout-scale-test.md`](../fanout-scale-test.md)):

- **Per-child execution time roughly halved** — p50 ~35 ms → ~19 ms (−46%), avg
  −49%, **flat from 20k to 100k**. This is the direct fsync-per-commit saving and it
  is robust and repeatable.
- **Aggregate throughput +20–30%, not 2×.** Once the child's own commits are
  cheaper, the **Solid Queue claim/finish cycle and the shared single-Postgres
  fsync budget** dominate per-slot time — halving one of several serial commits
  can't double the whole pipeline. The win also *compresses* with N (+30% at 20k →
  +22% at 100k) as that shared ceiling takes a larger share.
- **Dispatch got faster too** (100k fan-out 64 s → 53 s): lighter child commits free
  fsync headroom for the parent's `spawn_each` inserts.

So the measure-first question is answered: the workload **is** commit/fsync-bound,
and the consolidation is a clear, behaviour-preserving win — but the residual
ceiling is now the queue backend and the single-DB fsync budget, not engine work.

## Where the remaining headroom is

1. **Split the queue onto its own database/disk.** Solid Queue's claim/finish
   fsyncs currently compete with engine-commit fsyncs for one budget; separating
   them lets the two streams run in parallel. Likely a bigger aggregate lever than
   any further engine shaving.
2. **Bulk / lightweight child mode** for large sets of trivial, idempotent items —
   the path to order-of-magnitude gains, with its isolation/observability
   trade-offs made explicit and opt-in (see above).
3. **Scale the write tier out** (sharded Postgres) for raw commit headroom.

Do not expect a 10× from further commit consolidation — the engine is no longer the
wall. That comes from (1)/(2) or scaling the write tier.
