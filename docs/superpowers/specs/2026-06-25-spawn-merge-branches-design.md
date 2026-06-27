# Branches — Concurrent Sub-Workflows (`branch` / `spawn` / `merge_branches`) — Design

**Date:** 2026-06-25
**Status:** Implemented (branch `feat/branches`).
**Scope:** New public API, additive. Introduces parent/child workflows and a
fan-out/fan-in primitive built to dispatch **hundreds of thousands** of children per
branch. One new (generic, reusable) column on `chrono_forge_workflows`; reuses the
execution-log pattern for coordination. No breaking change to existing single-workflow
execution. **New dependency floor:** `activejob >= 7.1` (for `perform_all_later`).

## Problem

ChronoForge workflows are strictly sequential. The only way to fan work out today is to
hand-enqueue independent workflows and poll for them with `wait_until` — a hand-rolled
fork/join with no idempotent dispatch and no parent/child visibility.

Real workflows need durable, large-scale fan-out: "spawn one sub-workflow per record
across a 500k-row set, run them in parallel, continue once all are done." It must be
crash-safe, idempotent under replay, and must not hold the batch in memory or serialize
on a hot row.

## Goal

A **branch** is the unit of fan-out — a durable step that wraps the work it spawns and
ties it together for the join. `spawn`/`spawn_each` exist **only inside a `branch`
block**. The model mirrors git: you branch, then you merge.

- `branch(name, automerge: false, &block)` — opens branch `name` (the durable
  `branch$<name>` log), runs the block to **eagerly dispatch** children, and **seals**
  when the block closes. Returns immediately (does **not** wait) so branches run
  concurrently.
- `spawn(name, WorkflowClass, **kwargs)` — inside a branch: dispatch a **single** named
  child.
- `spawn_each(name, source, of:) { |item| [WorkflowClass, kwargs] }` — inside a branch:
  dispatch **one child per item**, streamed like ActiveRecord batch loading; AR items are
  keyed `name_<record.id>` (primary key); plain enumerables are keyed `name_{index}`
  (sequential index).
- `merge_branches(*names)` — the **separate** join: halt until every named branch is
  sealed **and** all its children have completed.

```ruby
def perform(cycle_id:)
  branch :fulfillment, automerge: true do        # the step; seals when the block closes
    spawn :reconcile, ReconcileWorkflow, region: "EU"   # single child of :fulfillment
    spawn_each :orders, Order.pending do |order|        # bulk, streamed; keys orders_<id>…
      order.priority? ? [PriorityOrderWorkflow, { order_id: order.id }]
                      : [OrderWorkflow, { order_id: order.id }]
    end
  end

  branch :invoicing do                           # a second, concurrent branch
    spawn_each :invoices, Invoice.unpaid do |inv|
      [InvoiceWorkflow, { invoice_id: inv.id }]
    end
  end

  do_other_work                                  # both branches already running

  merge_branches :invoicing                      # join :invoicing; :fulfillment auto-merges
  durably_execute :finalize
end
```

## Decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| Keywords | **`branch` / `spawn` / `spawn_each` / `merge_branches`** — git branch/merge metaphor; `spawn` avoids shadowing `Kernel#fork`. |
| Branch = the step | A branch **is** its `branch$<name>` execution log. `spawn`/`spawn_each` are valid **only inside a `branch` block** (raise otherwise) — spawns don't exist without a branch. |
| Dispatch timing | **Eager.** Spawns insert + enqueue as the block runs; children start at once. The branch **seals** (log → `completed`) when the block closes. |
| Join | **Separate `merge_branches`** so branches run concurrently and work can happen in between. Joins one or more named branches at once (`merge_branches :a` for one). |
| `merge_branch` alias | **Ship a singular `merge_branch(name, **opts)` alias** that delegates to `merge_branches` — reads naturally for the common one-branch case (`merge_branch :a`) without a plural-method/singular-arg mismatch. Decided, not just mentioned. |
| Automerge | A property **of the branch**: `branch(name, automerge: true)`. When `true`, `branch` eagerly dispatches inside the block and then immediately calls `merge_branches(name)` at the block's close — execution does not continue past the block until the branch's children complete. No explicit `merge_branches` is needed. |
| Branch tracking | An **in-memory registry** (`@open_branches`), rebuilt each replay pass: `branch` adds, `merge_branches` removes on completion, the completion gate inspects the remainder. Deterministic replay makes it exact — no persisted `merged`/`automerge` flags. |
| Every branch must be joined | **No detached branches.** Any branch remaining in `@open_branches` at completion (neither `merge_branches`-d nor automerged) **raises `UnmergedBranchError`** (fail-fast on a forgotten join), rather than silently letting children run orphaned. `automerge: true` branches are joined inline at the block close and are absent from `@open_branches` by the time the completion gate runs. |
| Spawn identity | Spawns are **named** (`spawn :reconcile, …`, `spawn_each :orders, …`). The name anchors the child key and the per-`spawn_each` cursor — stable across code reordering (unlike a positional ordinal). AR items are keyed `name_<record.id>` (primary key); plain enumerable items are keyed `name_{index}` (sequential index). |
| Bulk source | `spawn_each` **streams** the source — `find_in_batches(batch_size: of, start: cursor)` for AR — never materialising the batch in memory. Scales to millions. |
| Child class | **Returned from the block** (`[WorkflowClass, kwargs]`); one branch may fan out into mixed workflow types. |
| Child key | Deterministic: `spawn` → `"#{parent.key}$#{branch}$#{spawn_name}"`; AR `spawn_each` item → `"#{parent.key}$#{branch}$#{spawn_name}_#{record.id}"`; enumerable item → `"#{parent.key}$#{branch}$#{spawn_name}_#{index}"`. Idempotency falls out of the unique-key constraint. |
| Cursor | Per `spawn_each`, stored in the `branch$<name>` log's `metadata` keyed by **spawn name** as `{ pk: <keyset>, n: <count/index> }`; persisted **once per dispatched chunk** (bundled with that chunk's `insert_all`). |
| Completion | **Poll**, no counter: a branch is done when sealed and has no incomplete children (`branch_log.spawned_workflows.where.not(state: :completed)` empty — read as an O(CAP) capped count). Zero per-completion contention. |
| Poll mechanism | A dedicated lightweight `ChronoForge::BranchMergeJob` (plain ActiveJob — no lock/replay/context) does the repeated probing and wakes the parent only at completion. The heavy parent runs just twice per merge (kick off + wake). No separate recovery timer. |
| Poll cadence | **Adaptive, capped-count.** `pending = incomplete.limit(CAP).count` (**O(CAP)**, never O(N)); next delay `clamp(pending * factor, min_interval, max_interval)` — fast when few remain, slow when many. |
| Determinism | AR items are keyed by **primary key**, so the stream is stable by construction. `spawn_each` rejects an AR relation carrying an explicit `.order` by checking `order_values.present?` up front (raises `NotExecutableError`). Plain enumerable items are keyed by **sequential index** and must re-enumerate deterministically (documented contract). |
| Failure semantics | **Option A.** A `stalled`/`failed` child keeps the branch incomplete; the parent stays parked; the user recovers the child (`retry_now`/`retry_later`) and the merge then resolves. No new failure states, no cascade. |
| Nesting | **Free.** A child is a workflow and may open its own branches; the tree forms via `parent_execution_log_id` (child → branch log → parent workflow). |

## Public API surface

```ruby
branch(name, automerge: false) do
  spawn(name, WorkflowClass, **kwargs)
  spawn_each(name, source, of: 1000) { |item| [WorkflowClass, kwargs] }
end

merge_branches(*names, min_interval: 5.seconds, max_interval: 5.minutes)  # halts until done
merge_branch(name, **opts)   # singular alias for the common one-branch case
```

`spawn`/`spawn_each` raise `NotInBranchError` if called outside a `branch` block. A branch
opened but neither `merge_branches`-d nor `automerge: true` raises `UnmergedBranchError` at
workflow completion.

## Data model

`chrono_forge_workflows` gains **one** nullable column (inline in the install migration;
a follow-up migration template for existing installs):

| Column | Type | Notes |
|---|---|---|
| `parent_execution_log_id` | FK → `chrono_forge_execution_logs.id`, nullable, indexed | The execution log that spawned this workflow. For branches it's the `branch$<name>` log. **Deliberately generic** — any future step that spawns sub-workflows reuses it. |

The branch a child belongs to *is* its `parent_execution_log_id` (the `branch$<name>`
log), which is globally unique and encodes both the parent workflow (the log's
`workflow_id`) and the branch (its `step_name`). No `branch_name`/`parent_workflow_id`
column is needed.

**Merge/automerge state is not persisted.** It's tracked in an in-memory registry rebuilt
each replay pass from the `branch`/`merge_branches` calls (see Execution flow) — `branch`
adds, `merge_branches` removes, the completion gate inspects the remainder. Deterministic
replay makes this exact every pass, so no `merged`/`automerge` columns or metadata flags
are needed; the branch log holds only dispatch cursors.

**Composite index** `(parent_execution_log_id, state)` — makes the merge capped count
and the dropped-job re-kick index-only and short-circuiting at millions of rows.

No new table. The branch is the **`branch$<name>`** execution log (two-segment, like
`durably_repeat`'s coordination log — preloaded when sealed, never per child):

```
step_name: "branch$fulfillment"
state:     pending (dispatching) | completed (sealed / block closed)
metadata:  { "cursors" => { "orders" => { "pk" => <keyset>, "n" => <count> } } }  # keyed by spawn name
```

The **`merge$<names>`** log coordinates a join (`pending` while polling → `completed`).

`Workflow belongs_to :parent_execution_log, class_name: "ExecutionLog", optional: true`;
`ExecutionLog has_many :spawned_workflows, class_name: "Workflow", foreign_key: :parent_execution_log_id`.
A branch's children are `branch_log.spawned_workflows`; the parent is `branch_log.workflow`.

### One bounded log per branch — preload safety

The preload (`completed_step_cache`) bulk-loads all `completed` logs except
`durably_repeat$%$%` (the unbounded three-segment repetition logs). A two-segment
`branch$<name>` is preloaded when sealed, so a replay past the branch short-circuits.
**Per-child state is never modelled as sub-segment logs** (`branch$<name>$<child>`):
those would be pulled into the preload and load millions of rows on every replay.
Per-child state lives on the child workflow rows; the branch log holds only cursors.

## Execution flow

### `branch(name, automerge:) { … }` — wrap + eager dispatch + seal

Gated by `find_or_create_execution_log!("branch$#{name}")` (the branch log holds only
dispatch cursors; `automerge`/merge state is in-memory, not seeded here):

1. **Sealed** (`completed`, served from `completed_step_cache`) → already fully
   dispatched; **skip the block entirely** (no re-stream) and return. *(This short-circuit
   is the single most important correctness/performance property in the design — the
   expensive source enumeration never re-runs after sealing. It warrants a prominent comment
   directly above the skip path in the implementation.)*
2. **Pending / new** → set the current-branch context, **yield the block** (named spawns
   dispatch into this branch, advancing their cursors — see below), clear the context,
   mark the `branch$<name>` log `completed` (**sealed**). If `automerge: true`, immediately
   call `merge_branches(name)` — **execution does not continue past the block** until the
   branch's children complete (identical to an explicit `merge_branches` call placed right
   after the block, but guaranteed by the method). Otherwise **return** without halting —
   branches are concurrent; the explicit join is separate.

Either way, `branch` **registers the branch in the in-memory registry**
`@open_branches[name] = { automerge:, log_id: }` — this runs on *every* pass (sealed or
not), since the `branch` method itself always executes even when its block is skipped.

`spawn`/`spawn_each` read the current branch from that context and raise
`NotInBranchError` if there is none.

### `spawn` / `spawn_each` — dispatch within a branch

- **`spawn(name, klass, **kwargs)`** → one child, key `"#{parent.key}$#{branch}$#{name}"`,
  `job_class: klass.name`, `parent_execution_log_id: branch_log.id`. Idempotent on the key.
- **`spawn_each(name, source, of:)`** → stream, resuming from `metadata.cursors[name]`
  (`{ pk:, n: }`); `n` is a running count (AR) or the resume index (enumerable):
  - **AR relation:** rejects `source` if `source.order_values.present?` (raises
    `NotExecutableError` — iteration is by PK and an explicit order conflicts). Resumes via
    `source.find_in_batches(batch_size: of, start: cursor.pk)`. Per batch, for each record: `klass, kw =
    yield(record)`; build child rows (key
    `"#{parent.key}$#{branch}$#{name}_#{record.id}"`, `job_class`, `kwargs`,
    `parent_execution_log_id: branch_log.id`, `state: :idle`); `insert_all(…, unique_by:
    :key)` (on-conflict-ignore); enqueue only those children still `:idle` (dispatch is
    **queue-idempotent** — a crash-resume never re-runs an already-completed/running child);
    advance `metadata.cursors[name]` to `{ pk: batch.last.id, n: n + batch.size }`
    (committed with the inserts).
  - **Enumerable:** resume via `drop(n)`; child key uses `name_#{n}` (sequential index);
    same per-chunk insert/idle-filter/enqueue/advance (`n` only).
  - Enqueue the chunk, **then** advance the cursor — a crash in between re-enqueues only
    that one chunk on resume (idempotent).

### `merge_branches(*names)` — separate poll-join

Each name is validated up front: `$` is rejected via `validate_step_name_segment!`, and `,`
(the merge step-name separator) is also rejected — both raise `InvalidStepName`.

Gated by `find_or_create_execution_log!("merge$#{names.sort.join(',')}")`:

1. **Completed** → return, continue.
2. For each `name`: require it to be in `@open_branches` (opened earlier this pass) — a name
   that was never opened **raises `UnknownBranchError`** (a `NotExecutableError` subclass,
   so it fail-fasts via the existing rescue without broadening the executor); a not-yet-sealed
   branch means "still dispatching".
3. **Capped-count probe** per branch:
   `branch_log.spawned_workflows.where.not(state: :completed).limit(CAP).count`
   (`where(parent_execution_log_id: branch_log.id, …)`, index-only, **O(CAP) not O(N)**).
   All `0` → done. Otherwise enqueue a `BranchMergeJob` (which polls + re-kicks dropped
   jobs) and `halt_execution!`.
4. All branches `0` pending → **delete those names from `@open_branches`** (so the
   completion gate sees them as joined), mark the `merge$…` log `completed`, continue.

Completion is **poll-based**, delegated to a dedicated lightweight job so the heavy
parent isn't replayed per check:

- `merge_branches` does **one** immediate check; if not done, enqueues
  `ChronoForge::BranchMergeJob` and `halt_execution!`s (parent → `idle`, lock released).
  The parent runs only **twice** per merge: kick off + completion wake.
- **`BranchMergeJob`** is a plain ActiveJob — *no* lock, replay, or context. Each run:
  ```ruby
  pending = branch_log_ids.sum { |id| incomplete(id).limit(CAP).count }   # O(CAP), index-only
  if pending.zero? && all_sealed?(branch_log_ids)
    ParentWorkflow.perform_later(parent_key)                 # wake the parent once
  else
    rekick_dropped_jobs(branch_log_ids)                      # idle re-kick lives here
    delay = [[pending * factor, min_interval].max, max_interval].min   # adaptive cadence
    self.class.set(wait: delay).perform_later(parent_key, branch_log_ids, min_interval, max_interval)
  end
  ```
- On the wake, the parent replays once; sealed branches short-circuit (no re-stream),
  `merge_branches` re-checks, marks the `merge$<names>` log `completed`, and continues.
  **The parent completes its own merge step** — the poller only *detects* and wakes.

`merge_branches` **(re)spawns a poller whenever reached while still pending**, so a manual
retry of a parked parent self-heals a lost poller (including when the poller was spawned by
an automerge inline call); a rare double-poller from an external re-trigger is harmless (the
wake is idempotent).

**No separate recovery poll.** The poller is a durable backend-scheduled job — the same
durability `wait_until`'s reschedule already relies on. A lost poller just parks the
parent with a pending `merge$…` log, recoverable by retry (Option A). Cost: one tiny job
per (adaptive) interval plus an **O(CAP)** index-only capped count per branch — no
counter, no per-child shared write, no hot-row contention at any scale; latency falls
toward `min_interval` as the branch nears done. Option A falls out — a failed child keeps
pending > 0, so the parent waits until it is recovered.

### Completion gate — every branch must be joined

Every branch must be joined — explicitly via `merge_branches` or implicitly via
`automerge: true`. **There is no detached branch.** `complete_workflow!` (`enforce_branch_joins!`)
gains a gate **before** it seals the workflow that inspects `@open_branches` — the in-memory
registry that `branch` populated and `merge_branches` pruned during this pass (rebuilt
deterministically every replay, so it's exact). The gate does **only** the unmerged-raise
check:

1. **Unmerged check:** any branch remaining in `@open_branches` at completion is a forgotten
   join → **raise `UnmergedBranchError`** naming the branch(es), with the hint *"add
   `merge_branches :x` or `branch(:x, automerge: true)`."* This fails the workflow fast
   rather than letting children run orphaned; the developer fixes the code and retries. The
   check is unconditional (fires even if the branch's children happen to have finished) so
   the contract is deterministic, not timing-dependent.

(A branch joined via `merge_branches` was already deleted from `@open_branches` when that
merge completed, so it's absent here. An `automerge: true` branch is also absent — its join
ran inline at the `branch` block's close, removing it from `@open_branches` before
execution ever continued past the block.)

## Determinism

The cursor is only meaningful if iteration is reproducible across replays:

- **AR relation:** children are keyed by **primary key** (`name_<record.id>`), so the
  mapping from record to child key is stable regardless of enumeration order. Iteration is
  driven by **primary-key keyset** (`find_in_batches(start:)`). `spawn_each` rejects a relation
  carrying an explicit `.order(...)` by checking `order_values.present?` up front (raises
  `NotExecutableError`) — relying on `find_in_batches`'s `error_on_ignore` is not
  sufficient because `find_in_batches(start:)` is inclusive and a crash-resume re-yields
  the boundary record; the explicit up-front check catches order conflicts before any
  inserts occur.
- **Enumerable:** items are keyed `name_{index}` by their **sequential position** in the
  stream, so the source must re-enumerate identically across replays (effectively frozen
  for the brief dispatch window — once the branch seals, replay skips the block, so no
  re-enumeration happens thereafter). Deterministic re-enumeration is a documented,
  unverifiable contract — misuse is still *safe* (`insert_all`-ignore + poll) but could
  dispatch the wrong set.

## Idempotency & crash recovery

Three layers — **what exists** (DB), **how far dispatch got** (cursor), **step state**
(the log).

- **`find_or_create_execution_log!`** — a sealed `branch$<name>` skips the whole block;
  a completed `merge$…` short-circuits the join.
- **Deterministic keys + per-spawn cursors = "which children exist."** The branch never
  tracks children individually. Existence is owned by the unique index (`insert_all`-ignore
  is a no-op for rows that exist); dispatch progress is owned by `metadata.cursors[name]`.
  Recovery resumes from the cursor and re-touches **one chunk**, not the whole set.
  *(Dispatch is not bound to the create block: a crash after the log is created must still
  create and enqueue the remaining rows, or the branch would stall forever.)*
- **`:idle` filter for dropped jobs.** A child dispatched but never run is re-kicked from
  the `BranchMergeJob` poll: re-enqueue branch children with `state: :idle` in an
  incomplete branch. Branch children are pre-inserted with `state: :idle` and never get
  `started_at` set before execution, so `:idle` is the correct "never picked up" signal
  (filtering by `started_at IS NULL` would be unreliable). *Child existence is not enough;
  the merge guarantees every member is actually queued.* (verbatim into the code comment.)
  The re-kick is batch-capped. Safe because re-enqueue is idempotent: `executable?` is
  `idle || running`, so `acquire_lock` raises `NotExecutableError` for a `completed` child
  (its dispatch can never double-fire) and `ConcurrentExecutionError` for a `running` one.
  Children in other states (running, mid-halt, stalled/failed under Option A) are excluded
  by the `:idle` filter.

### Recovery walkthrough — 300,000 children, crash at 250,000

A `branch :fulfillment` block's `spawn_each :orders` had committed 250k child rows + jobs
with `metadata.cursors["orders"]` at `{ pk: <250,000th PK>, n: 250_000 }`; it was mid-chunk
when the process died. The `branch$orders` log is still `pending` (not sealed), so workflow retry replays
from the top. The block re-runs; `spawn_each` resumes `find_in_batches(start: cursor)` from PK
250,000 — re-touching ~50k rows, worst-case duplicate enqueue is the single in-flight
chunk. The 250k already dispatched keep running the whole time. When the source is
exhausted the block closes and the branch seals; `merge_branches`/automerge then polls to
completion. Recovery is bounded and idempotent — never a re-fan-out of 300k.

## Scale & performance (target: hundreds of thousands per branch)

| Operation | Frequency | Cost |
|---|---|---|
| `spawn_each` dispatch | once per branch, **streamed** | `⌈N/of⌉` `insert_all` + `perform_all_later`, each advancing the cursor — O(N) total, bounded chunks, **constant memory** |
| Child run | per child | one own-row state transition — **no shared-row contention** |
| Merge poll | per adaptive interval | lightweight `BranchMergeJob` running an **O(CAP)** capped count per branch; interval scales `min`↔`max` with pending — the heavy parent is *not* replayed per poll |
| Crash recovery | once | resumes dispatch from the cursor — re-touches **one chunk** |
| Replay cost | per resume | independent of how many children finished — no member list, no sibling scan, no counter |

What deliberately does **not** exist: an in-memory fork registry (streamed instead), a
single hot completion counter (adaptive capped-count poll instead), and a member-key blob
in metadata (just per-spawn cursors). The remaining O(N) work — N rows + N jobs — is
irreducible for N sub-workflows, done in bounded chunks by one parent job.

### `perform_all_later` — verified (activejob 7.1.3.4)

- **Mixed job classes: supported, no same-class requirement.** `perform_all_later` groups
  by `queue_adapter` (`enqueuing.rb:18`); the adapter's `enqueue_all` then sub-groups by
  **class then queue** (e.g. core Sidekiq adapter does `group_by(&:class).group_by(&:queue_name)`
  → one `push_bulk` per group, `sidekiq_adapter.rb:36`). So a `spawn_each` returning mixed
  workflow types is fine — enqueue just batches per distinct (class, queue), never falling
  back to per-job for being heterogeneous.
- **It bypasses ChronoForge's class-level `perform_later` override** (`__validate_enqueue!`)
  and **ActiveJob enqueue callbacks** — it builds instances and hits the adapter directly.
  So `spawn`/`spawn_each` must **build child job instances and validate them
  (String key, no reserved kwargs) themselves**, then `ActiveJob.perform_all_later(jobs)`.
  Execution is unaffected (the executor's logic is in instance `perform`). This mirrors the
  existing sanctioned `.set(...)`-bypasses-the-override pattern.
- **Requires activejob ≥ 7.1.** The gemspec currently pins no version — add
  `spec.add_dependency "activejob", ">= 7.1"` (or provide a `perform_later`-loop fallback).
- **Bulk enqueue is adapter-dependent.** Only adapters implementing `enqueue_all`
  (Sidekiq in core; solid_queue/good_job ship their own) batch the enqueue; Test/Inline/
  Async fall back to per-job `enqueue`. The `insert_all` of child rows is **always** bulk;
  job enqueue batching is best-effort.

Other caveats to verify in the plan:
- `find_in_batches` `start:` semantics (inclusive boundary — the boundary record is re-yielded on
  crash-resume; PK-keyed children dedup via `insert_all`-ignore) and the per-adapter
  bind-param limit for the `of:` chunk size (notably SQLite's `SQLITE_MAX_VARIABLE_NUMBER`).
- The merge capped count must be index-only on `(parent_execution_log_id, state)`.

## Poll-cadence constants (class-configurable defaults)

- `CAP` (capped-count limit) — default `5_000`. Bounds each poll's count cost; beyond it,
  pending saturates to `max_interval` (no signal lost).
- `factor` — maps pending → delay; default tuned so ~100 → ~10s, ~1k → ~1 min.
- `min_interval` / `max_interval` — clamp; defaults `5.seconds` / `5.minutes`
  (per-`merge_branches` overridable; `automerge` uses the defaults).

## Naming & validation

- `STEP_NAME_DELIMITER` is `$` (executor.rb). Reserved.
- The `branch` name, each `spawn`/`spawn_each` name, and each `merge_branches` name pass
  through `validate_step_name_segment!` (no `$`). The merge step name joins sorted branch
  names with `,`; names containing `,` are rejected. (`name_{index}` uses `_`, which is
  unreserved.)
- Child keys use `$` (`"#{parent.key}$#{branch}$#{spawn_name}"` / `…$#{spawn_name}_#{index}"`).
  Keys are opaque (never parsed), so a `$` already in the parent key is harmless.

## Non-goals (v1) — with caveats

- **Sharded completion counter / instant wake.** v1 polls (adaptive, but still polls). If
  sub-`min_interval` wake latency is ever needed, a
  `fork_counters(branch_log_id, shard, completed)` table (K rows/branch) is the upgrade —
  fully internal to the branch, **zero API change**.
- **Parallel dispatch.** One parent job streams the dispatch. At ~1M this is minutes and
  crash-safe via the cursor; recursive dispatcher sub-jobs are a future throughput upgrade.
- **Result aggregation.** Children communicate via their own `context`, which is
  **workflow-scoped** — a parent can't read a child's context today. `branch_log.spawned_workflows`
  returns the child **records**. Aggregation, when added, needs an explicit cross-workflow
  read API.
- **`merge_branches` timeout.** Blocks indefinitely (Option A); a `timeout:` can come later.
- **Dashboard nesting.** Parent/child tree + per-child recovery is a follow-up; the
  `parent_execution_log_id` column makes the tree cheap to walk.

## Testing strategy

Mirror the existing `ChaoticJob` style (`perform_later` + `perform_all_jobs`; assert on
workflow `state`, `execution_logs`).

- **Happy path:** a `branch` with a `spawn :a` + a `spawn_each :b`; assert child keys
  (`…$a`, `…$b_0`, `…$b_1`, …), `parent_execution_log_id`, the branch seals,
  `merge_branches` resumes, the workflow finishes.
- **Spawn outside branch raises** `NotInBranchError`.
- **Concurrency:** two branches dispatched before the merge both make progress before the
  join; work between branch blocks and merge runs while children are in flight.
- **Eager dispatch:** children begin before `merge_branches` is reached.
- **Class from body:** a `spawn_each` returning mixed classes creates children with the
  right `job_class` per item (and they bulk-enqueue together).
- **Determinism guard:** an AR relation with a conflicting `.order(...)` **raises**.
- **Crash mid-dispatch (cursor resume):** glitch after chunk *k*; assert
  `metadata.cursors[name]` (`{ pk:, n: }` for AR; `{ n: }` for enumerable) persisted,
  dispatch resumes from it (not 0), final child count correct, no duplicate rows, only the
  in-flight chunk re-enqueued. (250k-of-300k.)
- **Dropped-job re-kick:** a sealed branch with a child whose job was lost (state `:idle`,
  never started); assert the poll re-enqueues exactly that child and then resolves.
- **Poll job:** assert the parent runs only twice (kick-off + wake) regardless of poll
  count; a manual retry of a parked parent re-spawns the poller.
- **Adaptive cadence:** assert the count is capped at `CAP` (a branch with ≫CAP incomplete
  issues an O(CAP) count and picks `max_interval`); the delay shrinks toward `min_interval`
  as pending drops.
- **Automerge:** an `automerge: true` branch blocks execution inline at the block's close
  (not at workflow completion) — assert execution does not continue past the block until
  children finish, and that the `merge$<name>` log exists and is `completed` before the
  next step runs. No explicit `merge_branches` is needed.
- **Unmerged branch raises:** a branch opened with neither `merge_branches` nor
  `automerge: true` raises `UnmergedBranchError` at the completion gate (unconditional —
  fires even if children already finished), naming the branch.
- **Option A:** a child `permanently_fail`s → merge parks; recover via `retry_later` →
  merge resolves; assert no progress while parked.
- **Idempotency / replay:** force replays; assert constant child count, no re-dispatch once
  sealed, replay query count independent of completed-child count (`branch$<name>` preloads
  when sealed; no per-child sub-logs).
- **Scale:** a branch of hundreds of thousands; assert `insert_all` issues `⌈N/of⌉` inserts
  (not N), constant memory (streamed), contention-free child runs, and one capped probe per
  branch per poll. (Job-enqueue batching is adapter-dependent — under the test adapter it
  falls back to per-job enqueue, so don't assert bulk *enqueue* there.)
- **Empty branch / empty source:** seals immediately; the merge resolves at once.
- **Nesting:** a child opens its own branch; assert the tree completes bottom-up.

## README notes (when shipping)

Surface these prominently in user-facing docs, not just here:
- **Every branch must be merged or `automerge: true`** — otherwise `UnmergedBranchError`.
- **The heavy parent is not replayed per poll** — a lightweight `BranchMergeJob` does the
  waiting; the parent runs twice per merge.
- **AR source must be stable during a branch's dispatch window** — AR items are keyed by
  primary key (`name_<id>`), so inserting rows mid-dispatch is safe but re-use of a PK
  (soft-delete/re-insert) can confuse the cursor. Plain enumerables are keyed by sequential
  index; inserting/removing items mid-dispatch (before a crash-replay seals the branch)
  shifts indices. Once sealed, the block never re-enumerates.

## Future work

- Sharded-counter table for instant (non-poll) wake.
- Parallel/recursive dispatcher sub-jobs for dispatch throughput beyond one parent job.
- Result aggregation via an explicit child-context read API.
- `merge_branches(..., timeout:)`.
- Dashboard parent/child tree + per-child recovery actions.
