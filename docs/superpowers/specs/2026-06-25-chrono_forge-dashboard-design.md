# ChronoForge Dashboard — Design

**Date:** 2026-06-25
**Status:** Approved (pending spec review)
**Scope:** New companion gem `chrono_forge-dashboard`, a mountable Rails engine.
Additive; does not change the published `chrono_forge` gem.

## Problem

ChronoForge exposes rich per-step data (execution logs, error logs, persistent
context, wait states, periodic tasks) but no UI. Operators recover stalled
workflows and inspect failures from a Rails console. Competing job dashboards
(Sidekiq, GoodJob, Mission Control) show queues and jobs, not the interior of a
long-running workflow. A free, self-contained dashboard over ChronoForge's data
is both a useful tool and the project's strongest adoption lever.

## Goal

A mountable, zero-build Rails engine giving full visibility and operational
control over ChronoForge workflows: list/triage, a step **replay timeline**, a
context inspector, periodic-task health, wait-state age, and the recovery actions
(`retry_later`, force-unlock, bulk retry) — behind fail-closed auth.

## Decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| Repo layout | **Monorepo subfolder** `chrono_forge-dashboard/` with its own gemspec; core gem excludes the dir from `spec.files` so the published `chrono_forge` stays lean. |
| Scope | **Full build** — all tiers (visibility, triage, timeline, periodic health, wait-state, actions) in v1. |
| Frontend | **Server-rendered, zero-build** — ERB + one bundled CSS + one vanilla JS file, served by the engine itself. No npm/bundler/importmap; CSP-friendly; polling for live updates. |
| Auth | **Fail-closed, pluggable** — built-in HTTP Basic, a custom hook, or explicit `:none` (to use routing constraints). Mounting without configuring any of them **raises**. |
| Data | **Reuse core models read-only**; engine holds its own query objects/presenters. No schema changes; minimal-to-no core changes. Offset pagination. |
| Engine | Namespace-isolated `ChronoForge::Dashboard::Engine`, Zeitwerk-loaded. |

## Architecture

```
chrono_forge/                         # repo root (core gem)
  lib/ chrono_forge.gemspec           # core; rejects chrono_forge-dashboard/ from spec.files
  chrono_forge-dashboard/
    chrono_forge-dashboard.gemspec    # add_dependency "chrono_forge", "railties"
    lib/chrono_forge/dashboard.rb         # config object + Engine
    lib/chrono_forge/dashboard/engine.rb
    app/controllers/chrono_forge/dashboard/...
    app/views/chrono_forge/dashboard/...
    app/assets/chrono_forge/dashboard/{dashboard.css,dashboard.js}
    app/queries/chrono_forge/dashboard/...     # query objects
    app/presenters/chrono_forge/dashboard/...  # timeline / context / sparkline builders
    test/                              # Combustion dummy app mounting the engine
```

Host mounts it:

```ruby
mount ChronoForge::Dashboard::Engine, at: "/chrono_forge"
```

`isolate_namespace ChronoForge::Dashboard` keeps routes/helpers/table-name
prefixes contained. Engine views and assets are wholly self-contained.

## Components

### 1. Configuration & auth (`ChronoForge::Dashboard`)

A config singleton:

```ruby
ChronoForge::Dashboard.configure do |c|
  c.http_basic = { username: ENV["CF_USER"], password: ENV["CF_PASS"] }  # built-in
  # c.authenticate { |controller| controller.head(:forbidden) unless controller.current_user&.admin? }
  # c.authentication = :none   # opt out; you mount behind your own routing constraint
  c.polling_interval = 5        # seconds; 0 disables auto-refresh
  c.page_size = 50
  c.long_wait_threshold = 1.hour
end
```

`BaseController` runs `before_action :authenticate!`, resolved fail-closed in
this order:

1. **hook present** → call it (host integrates Devise/Pundit/etc.).
2. **else `http_basic` present** → `authenticate_or_request_with_http_basic`.
3. **else `authentication == :none`** → permit (host guards via routing
   constraint).
4. **else → raise `ChronoForge::Dashboard::AuthenticationNotConfigured`** at
   request time, with a message naming the three options.

So a forgotten config fails loudly instead of leaking workflow context.

### 2. Read / query layer

- Reuses `ChronoForge::Workflow`, `ExecutionLog`, `ErrorLog` read-only.
- **`WorkflowsQuery`** — filter by `state`, `job_class`, `key` (search),
  date range; offset-paginated; recency-sorted.
- **`StatsQuery`** — counts by state + recent failure rate in one grouped query
  (no N+1).
- **`StepNameParser`** — decodes step names into `{kind, name, timestamp}`:
  `durably_execute$<name>`, `wait_until$<condition>`, `durably_repeat$<name>`
  (coordination) and `durably_repeat$<name>$<ts>` (repetition). `$` is the core's
  reserved delimiter, so parsing is unambiguous.
- Detail-view logs are paginated (a `durably_repeat` workflow accumulates
  unbounded repetition logs; never load them all).

### 3. Presenters

- **`TimelinePresenter`** — orders a workflow's `execution_logs` into a replay
  sequence; each entry: kind, status (completed/failed/pending/waiting),
  attempts, started/completed, duration, error summary. Repetitions roll up under
  their coordination log. Marks the "current position" (last failed/running, or
  the active wait).
- **`ContextPresenter`** — renders the JSON context as a collapsible tree with
  value types and a size-vs-16KB indicator. Read-only.
- **`PeriodicHealthPresenter`** — per `durably_repeat` coordination log: last run
  (`metadata.last_execution_at`), next scheduled, missed/timed-out count
  (repetition logs with `error_class == "TimeoutError"`), recent-latency
  sparkline data, and per-error `retry_counts` from metadata.
- **`WaitStatePresenter`** — for idle workflows whose latest step is a pending
  `wait_until`: condition, wait age (`now - last_executed_at`), `timeout_at`.

### 4. Controllers & routes

- `WorkflowsController#index` — list + stats + filters + pagination.
- `WorkflowsController#show` — detail: timeline, context, errors, wait callout,
  periodic health.
- `WaitStatesController#index` — idle-waiting workflows by wait age, flagging
  those past `long_wait_threshold`.
- `ActionsController` (POST, CSRF-protected):
  - `#retry` → `workflow.retry_later` (guarded by `retryable?`; 422 + flash if not).
  - `#unlock` → clear `locked_at`/`locked_by`, set `idle` (loud duplicate-exec warning in the UI).
  - `#bulk_retry` → `ChronoForge::Workflow.failed.find_each(&:retry_later)`; returns affected count.
- `AssetsController#show` — serves `dashboard.css` / `dashboard.js` with long-cache
  headers, so the engine needs no host asset pipeline.
- Fragment endpoints (`index`/`show` with a partial format) back the JS polling
  refresh.

### 5. Frontend

- ERB views + one layout; all classes prefixed `cf-`.
- One `dashboard.css`, one `dashboard.js` (vanilla), served by `AssetsController`.
- **CSP-friendly**: no CDN/external fonts; behavior attached via
  `addEventListener` + `data-` attributes (no inline `<script>` handlers, no
  inline event attributes).
- JS responsibilities: collapsible context tree; confirm dialogs for destructive
  actions; inline-SVG sparklines (no chart lib); polling that refreshes the
  list/stats fragment (and a running workflow's detail) every
  `polling_interval` seconds, with a pause toggle.

## Error handling

- Missing/legacy step names that don't parse fall back to a raw display rather
  than raising.
- Actions on a workflow whose state changed under the operator (e.g. retry on a
  now-running workflow) surface the core's `WorkflowNotRetryableError` as a flash,
  not a 500.
- Force-unlock always shows the duplicate-execution warning and requires confirm.
- Auth misconfiguration raises a clear, actionable error (see §1).

## Testing

Combustion dummy app (mirroring core's `test/internal`) mounting the engine, with
seeded workflows across every state and a `durably_repeat` workflow. Minitest +
standardrb.

- **Queries**: `WorkflowsQuery` filters/pagination; `StatsQuery` counts;
  `StepNameParser` for each kind incl. repetitions and unparseable names.
- **Presenters**: timeline ordering + repetition rollup + current-position;
  context tree + size indicator; periodic health (missed/timeout/sparkline);
  wait-state age.
- **Controllers**: index filters/pagination; show renders all panels; wait-state
  list + threshold flag.
- **Actions**: retry calls `retry_later` and guards non-retryable; unlock clears
  the lock; bulk retry count.
- **Auth**: raises when unconfigured; HTTP Basic accept/reject; hook;
  `:none` permits.
- **Assets**: `AssetsController` serves CSS/JS with cache headers.

## Build order (for the implementation plan)

Engine skeleton + gemspec + core `spec.files` exclusion + auth → list + stats +
filters → detail (context + errors) → step replay timeline → periodic health +
wait-state age → operational actions → assets + JS polling → README/docs. Each
step is independently testable.

## Out of scope (v1)

- Real-time push (ActionCable/SSE) — polling only.
- Editing context or workflow internals from the UI (read-only except the three
  actions).
- Cross-workflow search by context value (only key/class/state/date filters).
- Triggering `CleanupJob` from the UI (operator runs cleanup on their schedule).
