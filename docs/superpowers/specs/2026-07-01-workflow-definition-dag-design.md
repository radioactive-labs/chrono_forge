# Workflow Definition DAG — static "future timeline" for ChronoForge

**Status:** Design approved (pending written-spec review)
**Date:** 2026-07-01
**Reference:** the `durable_flow` gem's `DefinitionAnalyzer` (Prism-based static analyzer + definition DAG overlaid with runtime status).

## Problem

The dashboard today shows only the **historical** timeline of a workflow — the
`execution_logs` that have already run. There is no forward view: an operator
can't see the steps a workflow *will* run, where the current run sits in the
overall shape, or which branches/loops are still ahead.

ChronoForge workflows are plain Ruby: a `perform` method that the engine
**replays** every resume, with each durable step identified by a string name
(`durably_execute$name`, `wait_until$cond`, `branch$name`, `merge$a,b`,
`durably_repeat$name$<ts>`). Because the structure is expressed in source, we can
recover a *projection* of the step sequence by statically parsing `perform` with
Prism — without executing anything — and then paint the run's actual status onto
that static map.

## Goal

A **new per-run dashboard page** that renders a workflow's **conditional DAG**
(the static definition graph) with the current run's `execution_logs` **overlaid**
as node status. The existing workflow detail page is unchanged; it gains a link
to this page.

Non-goals for v1 are listed under [Scope](#scope-v1).

## Key decisions (locked during brainstorming)

1. **Primary consumer:** dashboard overlay — run status painted on the static map
   (mirrors durable_flow's run → definition-DAG view).
2. **Map shape:** a **conditional DAG** — guarded edges for `if`/`continue_if`,
   fan-out groups for branches, joins for merges.
3. **Fidelity:** **conservative + trace same-class helper methods**. Resolve step
   names statically where possible; anything unresolvable (computed `name:`,
   data-dependent loop count, a durable call behind an unknown/external call)
   becomes an explicit **`dynamic` node with a warning**. No unrolling, no
   cross-class tracing.
4. **Rendering:** **Mermaid.js** (client-side, vendored). The analyzer's graph
   model is rendering-agnostic; a renderer emits Mermaid flowchart text with
   status encoded as node classes.
5. **Static vs runtime:** static Prism analysis is the source of the *shape*
   (only it can show not-yet-run steps and untaken branches); the run log is the
   *overlay*, never the source of the graph.
6. **Placement:** a **new route/page**, not an inline addition to the detail page.

## Architecture

```
workflow_class
   │  DefinitionAnalyzer.call            (core gem; Prism; memoized by class + source digest)
   ▼
Definition (Node[], Edge[], warnings)    (plain, JSON-serializable value objects)
   │  DefinitionOverlay(execution_logs)  (dashboard; read-only queries; per-run; never cached)
   ▼
statused Definition
   │  MermaidRenderer                     (dashboard; statused graph → flowchart text)
   ▼
new DAG page  →  vendored Mermaid JS renders client-side (inside data-poll-region)
```

### Core gem — `lib/chrono_forge/` (rendering-agnostic, no dashboard/DB dependency)

- **`ChronoForge::DefinitionAnalyzer`** — `.call(workflow_class) → Definition`.
  - Resolves `workflow_class.instance_method(:perform).source_location`, reads the
    file, `Prism.parse`, locates the `perform` def node, and walks its body with a
    visitor.
  - **Traces durable calls in same-class helper methods** to a fixed point within
    the class (a call to a method defined on the same class whose body contains
    durable DSL calls is expanded inline; recursion is guarded).
  - Emits nodes, edges, and warnings. **Only reads source text — never touches the
    DB, never executes workflow code.**
- **`ChronoForge::Definition`** (+ `Node`, `Edge`) — plain value objects,
  JSON-serializable so a `Definition` can be cached.
  - `Node`: `id`, `kind` ∈ `{:execute, :wait, :wait_until, :continue_if, :branch,
    :merge, :repeat, :dynamic}`, `label`, and **either** an exact `step_name`
    **or** a `step_name_pattern` (fan-out/repeat/dynamic), plus optional `guard`
    (condition source label) and `warnings`.
  - `Edge`: `from`, `to`, optional `guard` label, and a `kind` (`:seq`,
    `:conditional`, `:fanout`, `:join`, `:terminal`).

### Dashboard package — `chrono_forge-dashboard/`

- **`DefinitionOverlay`** — takes a `Definition` + a workflow's `execution_logs`
  (and, for `:branch`/`:merge` nodes, child-workflow state counts via the existing
  `BranchProbe`) and annotates each node with a runtime `status`. Read-only.
- **`MermaidRenderer`** — `statused Definition → flowchart text`; status encoded
  as `classDef` + `class` assignments.
- **New controller action + view** — `GET workflows/:id/definition`, plus a
  "Definition graph" link from the existing detail page.
- **Vendored Mermaid JS** — the dashboard's first client script, initialized
  inside the existing `data-poll-region` so the DAG re-renders on the normal
  page refresh.

## Node → step-name binding

Each node knows the step-name it *would* produce, so the overlay is a lookup, not
guesswork:

| DSL call | Node kind | Binds to |
|---|---|---|
| `durably_execute :m` / `name: "x"` | `:execute` | exact `durably_execute$x` (or `$m`) |
| `durably_execute :m, name: <expr>` | `:dynamic` | prefix `durably_execute$`, by ordinal |
| `wait <duration>, "n"` | `:wait` | exact `wait$n` (name is the 2nd positional) |
| `wait_until :cond` | `:wait_until` | exact `wait_until$cond` |
| `continue_if :cond` | `:continue_if` | exact `continue_if$cond` |
| `branch :name { spawn/spawn_each }` | `:branch` (fan-out) | `branch$name` + child-workflow aggregate |
| `merge_branches :a, :b` | `:merge` (join) | `merge$a,b` (names sorted) |
| `durably_repeat :name` | `:repeat` (loop) | `durably_repeat$name` coord + `$<ts>` reps |

**Fan-out (`branch`/`spawn_each`) and `durably_repeat` collapse to a single node
with aggregate status** — not one node per child/iteration.

## Overlay status vocabulary (→ Mermaid classes)

- `done` — matching log is `completed`.
- `active` — log is `started`/`running`, not completed.
- `pending` — reached but not done (a coordination log exists, work outstanding).
- `not_reached` — no log yet.
- `failed` / `stalled` — from the log state.
- `conditional` — statically guarded; may be skipped.
- `dynamic` — unresolved name; bound by prefix + ordinal.
- `unmapped` — **a runtime log with no matching static node**; appended so
  analyzer gaps are surfaced, not hidden.

Aggregates:
- `:repeat` → "N done, current active, `till` met?" from the coordination log +
  its `$<ts>` repetition logs.
- `:branch`/`:merge` → child-workflow state counts (running/idle/completed/failed)
  via `BranchProbe`.

## Edges & conditionals

- Sequential DSL calls → `:seq` edges.
- `if`/`unless`/`case`/`&&`/`||`/early-return around a step → `:conditional` edge
  labeled with the condition source; steps only reachable under a guard render
  `conditional`.
- `continue_if` → a gate node; its false path is a `:terminal` edge (workflow
  halts).
- `branch` block → fans out (`:fanout`) to its spawn/`spawn_each` child-group;
  `merge_branches` is the `:join` those edges reconnect into.
- `each`/`times`/`while` containing durable calls → one node + a "dynamic loop
  count" **warning** (conservative — no unrolling).

## Error handling

The analyzer must never break the dashboard:

- Source unavailable (`source_location` nil, C-defined, `eval`'d, unreadable
  file) → return a `Definition` carrying a single `unavailable` warning; the page
  renders "can't be statically analyzed" gracefully. Never raises.
- Any Prism parse issue degrades the same way (Prism is error-tolerant).
- Missing/unloadable `job_class`, or a partially-resolved analysis → render what
  was found plus a warnings panel.
- **Analyzer is pure/read-only over source text**; the overlay does read-only
  queries only.

## Caching

- Memoize `Definition` by `job_class` + source-file digest — auto-invalidates on
  dev code reload, stable in prod.
- The **overlay is never cached** — it is per-run and changes every poll.

## Testing

- **Analyzer unit tests (no DB):** a fixture set of workflow classes — linear,
  conditional/`continue_if`, `branch`+`spawn_each`, `durably_repeat`, dynamic
  `name:`, helper-traced, unanalyzable loop — asserting node kinds, edges, guards,
  and warnings. Deterministic and fast.
- **Overlay tests (dashboard harness):** seed `execution_logs` + child workflows;
  assert per-node status, fan-out aggregates, repeat counts, and the `unmapped`
  path.
- **`MermaidRenderer`:** golden-text tests (statused `Definition` → expected
  flowchart string).

## Scope (v1)

**In:** all seven primitives as nodes + conditional edges + fan-out/repeat
aggregation + the overlay + the new per-run DAG page + Mermaid rendering;
same-class helper tracing.

**Out (deferred):**
- Cross-class helper tracing.
- Recursively expanding a spawned child *workflow class* into its own graph
  (v1 shows it as one fan-out node; "drill into child" is a future feature).
- Per-node ETA/timing beyond status + counts (that's the separate progress/ETA
  feature).
- A class-level (no-overlay) definition view (trivial later addition).

## Open questions / risks

- **Helper-tracing fixed point:** need a clear rule for what counts as "a durable
  call inside a same-class method" vs. ordinary work, and recursion/mutual-call
  guards. The analyzer stays conservative — when in doubt, emit a `dynamic` node +
  warning rather than a confident-but-wrong expansion.
- **Ordinal binding for dynamic siblings** is best-effort; if two dynamic
  `durably_execute` calls interleave at runtime out of source order, the overlay
  may mis-bind. Acceptable for v1 (surfaced as `dynamic`).
- **Mermaid as first client dependency** — keep it vendored and isolated so the
  rest of the dashboard stays server-rendered.
