# Dashboard Branch View — Design

**Date:** 2026-06-26
**Status:** Design only. **BLOCKED on the branches core feature**
([`2026-06-25-spawn-merge-branches-design.md`](2026-06-25-spawn-merge-branches-design.md),
itself still Draft). Nothing here can be built or tested until `parent_execution_log_id`,
`branch`/`spawn`/`merge_branches`, and the `spawned_workflows` association exist in the
core gem. This spec is written so it can be implemented the day branches ships.
**Scope:** additive views in the `chrono_forge-dashboard` engine. No core changes.

## Problem

With fan-out, a parent can park at `merge_branches` (Option A) because **one** child
among tens or hundreds of thousands is `failed`/`stalled`. Today there is no way to see
that: the parent looks idle, and the blocking child is a needle in a haystack. The branch
view exists to answer, in one screen: *which branch is blocking this parent, how many
children are outstanding, and which specific children are failed/stalled — with a Retry on
each.* It is what makes Option A (park until recovered) operable in production.

## What it consumes from the core (the contract)

This view reads only what the branches spec defines. If any of these change, this spec
changes with it.

- **Column** `chrono_forge_workflows.parent_execution_log_id` (FK → `execution_logs.id`,
  nullable) with composite index `(parent_execution_log_id, state)`.
- **Associations** `Workflow#parent_execution_log` (→ `ExecutionLog`) and
  `ExecutionLog#spawned_workflows` (→ `Workflow`, FK `parent_execution_log_id`).
- **Branch log:** an execution log with `step_name` `"branch$<name>"`,
  `state` `pending` (dispatching) | `completed` (sealed), and `metadata`
  `{ "automerge" => bool, "merged" => bool, "cursors" => { "<spawn>" => { "pk", "n" } } }`.
- **Merge log:** `"merge$<names>"`, `pending` while polling → `completed`.
- A child is a `Workflow`; its parent branch log is `child.parent_execution_log`; the
  parent workflow is `branch_log.workflow`.

The reusable `StepNameParser` (already in the engine) gains `branch` / `merge` kinds.

## Design

### 1. Branches panel on the parent's detail page

A new section on `workflows#show`, rendered only when the workflow has any `branch$%`
logs. One row per branch (`BranchPresenter`), showing **health**:

| Field | Source | Notes |
|---|---|---|
| name | `StepNameParser.parse(log.step_name).name` | |
| status | `log.state` | `completed` → **sealed**; `pending` → **dispatching** (still spawning) |
| join | `metadata.automerge` / `metadata.merged` | "automerge", "merged", or "unmerged" |
| dispatched | `sum(metadata.cursors[*].n)` + explicit `spawn` count | cheap (from metadata), avoids counting rows |
| pending | `spawned_workflows.where.not(state: :completed).limit(CAP).count` | **capped, index-only** (O(CAP)); shows `"5000+"` past CAP |
| blocked | `spawned_workflows.where(state: [:failed, :stalled]).limit(CAP).count` | the actionable number; rendered in rose when > 0 |

Each branch row links to its **children view** (below) and, when `blocked > 0`, a direct
"View blocked" link pre-filtered to failed/stalled.

A parent parked on a merge also surfaces its `merge$<names>` log(s) here ("merging
invoicing — pending"), so the park is legible.

### 2. Branch children view (drill-down)

A new route + controller, because a branch can hold **hundreds of thousands** of children
— they are never all rendered.

- Route: `GET /workflows/:workflow_id/branches/:branch_log_id` →
  `BranchChildrenController#show` (scoped to the branch log; verifies it belongs to the
  workflow).
- **Reuses `WorkflowsQuery`** over `branch_log.spawned_workflows` (same state/key filters,
  pagination). **Default filter: `failed` + `stalled` first** — the triage default, so the
  blockers are the landing view rather than page 1 of 500k.
- Reuses the existing `_workflow_row` partial (children are workflows) plus a per-row
  **Retry** (and the child's own key links to its detail).
- A capped state-count strip at the top (completed/running/idle/failed/stalled), each an
  O(CAP) index-only count rendered as `"N"` or `"CAP+"`.

### 3. Per-child recovery

Children are workflows, so recovery reuses the existing `ActionsController`:
- Per-child **Retry** (`workflow.retry_later`) in each row and on the child detail.
- A **"Retry all blocked in this branch"** bulk action: iterate
  `branch_log.spawned_workflows.where(state: [:failed, :stalled]).find_each(&:retry_later)`
  (a scoped sibling of the existing bulk-retry). After recovery the parent's merge poll
  resolves on its own (Option A) — the view does not touch the parent.

### 4. Child → parent linkage

On `workflows#show`, when `@workflow.parent_execution_log_id` is present, render a
**breadcrumb**: `parent key › branch <name> › this child`, linking to the parent and the
branch children view. Cheap: one `parent_execution_log` + its `workflow`.

### 5. Tree view (nested branches)

Branches nest (a child may open its own branches). The parent panel shows **one level**
(this workflow's branches + per-branch child summary); you navigate down by opening a
child (whose own detail shows its branches) rather than rendering an unbounded tree on one
page. The breadcrumb provides the up-path. This keeps every page O(page_size), never
O(tree).

## Components

- `app/presenters/.../branch_presenter.rb` — one branch log → health struct (capped
  counts, dispatched-from-cursor, sealed/merged flags).
- `app/presenters/.../branches_presenter.rb` — a workflow's `branch$%` + `merge$%` logs.
- `app/controllers/.../branch_children_controller.rb` — `#show`, scoped children list.
- `app/queries/.../workflows_query.rb` — extend to accept a base scope (so it can run over
  `branch_log.spawned_workflows`, not just `Workflow.all`).
- `ActionsController#bulk_retry_branch` — scoped bulk retry.
- Views: `_branches.html.erb` (panel on show), `branch_children/show.html.erb`,
  `_parent_breadcrumb.html.erb`; `StepNameParser` branch/merge kinds.
- Routes: nested `branches/:branch_log_id` under `workflows`; a member `bulk_retry` on it.

## Scale guardrails (non-negotiable)

- **Never** `group(:state).count` an unbounded child set on a page load. All counts are
  **capped** (`limit(CAP)`) and index-only on `(parent_execution_log_id, state)`, shown as
  `"CAP+"` past the cap — mirroring the merge probe.
- **Never** render more than one page of children. Default to the blocked subset.
- "Dispatched" total comes from `metadata.cursors` (`n`), not a row count.
- The branches panel issues at most ~2 capped probes per branch (pending, blocked) — bounded
  regardless of child count.

## Testing (once branches exists)

Seed parent + `branch$<name>` logs + child workflow rows with `parent_execution_log_id`
(no need to run real fan-out):
- branches panel: sealed vs dispatching; automerge/merged/unmerged; pending + blocked
  capped counts (incl. a `>CAP` case showing `"CAP+"`); rose styling when blocked > 0.
- children view: default filter shows only failed/stalled; state filter + pagination work
  over the scoped relation; per-child Retry calls `retry_later`.
- scoped bulk retry hits only that branch's failed/stalled children.
- breadcrumb: a child renders a link to its parent + branch; a non-child renders none.
- merge log surfaced when the parent is parked.

## Open questions (confirm on review)

1. **Counts beyond CAP** — show `"5000+"` (capped) everywhere, or pay an exact `COUNT` for
   the *blocked* number only (usually small) while capping pending? (Leaning: exact for
   blocked, capped for pending.)
2. **Children view default** — land on failed/stalled (triage), or all-with-failed-first?
   (Leaning: failed/stalled, with a clear "show all" toggle.)
3. **Tree depth** — one level per page + breadcrumb (this spec), or a shallow expandable
   tree for small fan-outs? (Leaning: one level; revisit if small-N trees feel clunky.)
