# ChronoForge::Dashboard

[![Gem Version](https://badge.fury.io/rb/chrono_forge-dashboard.svg)](https://badge.fury.io/rb/chrono_forge-dashboard)
[![Ruby](https://github.com/radioactive-labs/chrono_forge/actions/workflows/main.yml/badge.svg)](https://github.com/radioactive-labs/chrono_forge/actions/workflows/main.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A mountable Rails engine that provides visibility and operational controls for ChronoForge workflows.

> Requires [`chrono_forge`](https://github.com/radioactive-labs/chrono_forge). See the [main README](https://github.com/radioactive-labs/chrono_forge#readme) for workflow documentation.

Version: `0.1.0` (early release). The UI and config API may change before `1.0`.

[![ChronoForge dashboard](docs/screenshots/workflows.png)](docs/screenshots/workflows.png)

## Installation

Add to your application's Gemfile (requires `chrono_forge`):

```ruby
gem "chrono_forge-dashboard"
```

Then run:

```bash
bundle install
```

## Mounting

Add to `config/routes.rb`:

```ruby
mount ChronoForge::Dashboard::Engine, at: "/chrono_forge"
```

## Screenshots

| Workflow list | Analytics |
| --- | --- |
| [![Workflow list](docs/screenshots/workflows.png)](docs/screenshots/workflows.png) | [![Analytics](docs/screenshots/analytics.png)](docs/screenshots/analytics.png) |
| Filter by state/class/key, keyset pagination, capped state counts. | Completion/failure rate, throughput, top errors, queue health — per class. |

| Waiting | Repetitions |
| --- | --- |
| [![Waiting workflows](docs/screenshots/waiting.png)](docs/screenshots/waiting.png) | [![Repetitions](docs/screenshots/repetitions.png)](docs/screenshots/repetitions.png) |
| Oldest unresolved `continue_if` (event) wait per class — the silent stall. | A `durably_repeat` step's per-iteration runs, with catch-up skips (per-tick tombstones or a "caught up ×N" summary) and lateness. |

| Branches | Branch children |
| --- | --- |
| [![Branches panel](docs/screenshots/branches.png)](docs/screenshots/branches.png) | [![Branch children](docs/screenshots/branch-children.png)](docs/screenshots/branch-children.png) |
| Fan-out branches with exact **spawned / pending / never-started** counts (recorded by the poller — the immutable spawned total is counted once and cached when the branch seals) plus blocked count and merge state, and in-flight merges showing **live throughput (children/s) and ETA** while draining. | One branch's children with a **live stats header** (throughput/ETA, spawned, pending, never-started, dropped-child recovery) — blocked-first triage, capped state filters, retry per child. |

**Workflow detail** — step-replay timeline with errors inlined on the step that failed, periodic-task health, and arguments/context:

[![Workflow detail](docs/screenshots/workflow-detail.png)](docs/screenshots/workflow-detail.png)

**Definition graph** — a per-run static DAG of the durable steps a workflow *will* run (parsed from `perform` with Prism, never executed), with the run's status painted on each node — done / in progress / failed / not-yet-reached — plus guarded edges, early-`return` exits, and unmapped steps. Tap a node or edge to inspect its step name / guard:

[![Definition graph](docs/screenshots/definition-graph.png)](docs/screenshots/definition-graph.png)

A scheduled-payment recurrence with three reminder-ordering branches that reconverge on the charge. This run took the auto-charge branch (green); the other two branches were never reached (dimmed), the past-dismiss guard exits early to `halt`, and the final `process_payment` failed:

[![Definition graph — scheduled payment](docs/screenshots/definition-graph-scheduled-payment.png)](docs/screenshots/definition-graph-scheduled-payment.png)

## Authentication

The dashboard is fail-closed. If you mount it without configuring authentication, hitting any dashboard URL raises `ChronoForge::Dashboard::AuthenticationNotConfigured`. Configure one of the following in an initializer (e.g. `config/initializers/chrono_forge_dashboard.rb`).

Resolution order: custom hook, then HTTP Basic, then `:none`, else raise.

### HTTP Basic Auth

```ruby
ChronoForge::Dashboard.configure do |c|
  c.http_basic = { username: ENV["CF_USER"], password: ENV["CF_PASS"] }
end
```

### Custom Hook

```ruby
ChronoForge::Dashboard.configure do |c|
  c.authenticate { |controller| controller.head(:forbidden) unless controller.current_user&.admin? }
end
```

The block receives the current controller instance. Call `head(:forbidden)` or `redirect_to` to deny access; return normally to allow it.

### Disable (use routing constraints instead)

Set authentication to `:none` and guard the mount point yourself:

```ruby
ChronoForge::Dashboard.configure do |c|
  c.authentication = :none
end
```

```ruby
# config/routes.rb
authenticate :user, ->(u) { u.admin? } do
  mount ChronoForge::Dashboard::Engine, at: "/chrono_forge"
end
```

## Configuration

All options go in the same `configure` block as auth:

```ruby
ChronoForge::Dashboard.configure do |c|
  c.polling_interval         = 15                        # seconds; the default auto-refresh interval. 0 to disable.
  c.polling_interval_options = [0, 5, 10, 15, 30, 60, 300] # selectable intervals in the nav "refresh" control
  c.page_size                = 50                     # workflows per page
  c.long_wait_threshold      = 3600                   # seconds; wait-state ages above this are flagged
end
```

| Option | Default | Notes |
| --- | --- | --- |
| `polling_interval` | `15` | Seconds between auto-refreshes (the default). Most pages refresh in place (preserving filter text, focus, and scroll), so a draining fan-out's live throughput/ETA and counts update without a manual reload. The definition graph opts out: its interactive Cytoscape canvas can't survive an in-place morph, so it reloads fully instead and hides the refresh control. A viewer can override the interval with the nav "refresh" control (stored in a cookie). `0` disables. |
| `polling_interval_options` | `[0, 5, 10, 15, 30, 60, 300]` | Intervals (seconds; `0` = off) offered by the nav refresh control. |
| `page_size` | `50` | Workflows per page on the index. |
| `long_wait_threshold` | `3600` | Wait-state age in seconds above which a warning is shown. |

## Features

- **Workflow list**: state badges, filter by state/job class/workflow key, stats header showing counts by state
- **Workflow detail**: step replay timeline showing every `durably_execute`, `wait`, `continue_if`, and `durably_repeat` run; repetitions from `durably_repeat` appear nested under their coordination step
- **Definition graph**: a per-run static DAG of the durable steps a workflow *will* run — parsed from the `perform` method source with [Prism](https://github.com/ruby/prism) (never executed, never touches the DB) — with the run's live status overlaid on each node (done / in progress / pending / not-yet-reached / failed / unmapped, with per-node repeat counts and fan-out child tallies). Rendered client-side with [Cytoscape](https://js.cytoscape.org) (dagre layout): pan/zoom, and tap a node or edge to inspect its step name / guard. Reached from a "Definition graph" link on the workflow detail page. The analysis is deliberately *conservative*: `if`/`unless`/`case`/`continue_if` become guarded edges, an early `return` a dashed exit, `branch`/`spawn_each` a fan-out node, `durably_repeat` a loop node, and anything it can't resolve statically (a computed step name, a data-dependent loop, a durable call behind an unknown method) becomes a `dynamic` node with a warning rather than a confident-but-wrong graph. It also follows durable calls into helper methods in the same class, assignments, `&&`/`||`, and `case`/`in`, so a step one expression deep isn't missed. A workflow whose source can't be analyzed, or whose `perform` has no durable steps, degrades to a note, never an error.
- **Context inspector**: JSON tree view of the workflow's persistent context
- **Per-step error logs**: errors attributed to the step and attempt that raised them
- **Periodic-task health**: summary of each `durably_repeat` task (last run, next run, missed executions)
- **Wait-states view**: lists workflows in a wait state, with age flagged if above `long_wait_threshold`
- **Recovery actions**: retry a stalled or failed workflow, force-unlock a stuck running workflow (with a duplicate-execution warning), bulk retry all failed workflows

## Frontend

The dashboard is server-rendered and driven by [Turbo](https://turbo.hotwired.dev) (~94 KB, Turbo 8, vendored and served from the engine — no external host). **The host needs no npm, no build step, and no asset-pipeline configuration** — the compiled stylesheet ships with the gem. Turbo Drive handles all navigation and form submits as in-app visits (no full reloads, history-aware), so the interactive glue is a small delegated-listener vanilla JS file (`dashboard.js`). Action POSTs redirect with `303 See Other` so Turbo follows them; the auto-refresh uses Turbo's morph stream (see below). CSP-compatible (no external hosts or inline handlers).

Styles are written with [Tailwind CSS](https://tailwindcss.com) and precompiled into the shipped `dashboard.css`. Contributors editing views or styles rebuild it with the standalone compiler (no Node required):

```bash
bundle exec rake tailwind:build
```

Assets are cache-busted by a content digest, so a gem upgrade is picked up without a hard refresh.

**One exception:** the **Definition graph** page loads [Cytoscape](https://js.cytoscape.org) + [dagre](https://github.com/dagrejs/dagre) to lay out the DAG client-side (~670 KB total, loaded only on that page). All three libraries plus the init module (`definition_graph.js`) are vendored into the gem and served from the engine — no external host / CDN, and no inline `<script>` (the init is an external file), so the page stays CSP-friendly. The graph is passed as JSON in a `data-` attribute (ERB-escaped in, `JSON.parse`d out) and Cytoscape renders labels onto a canvas, so the graph itself has no HTML-injection surface. Unlike the old Mermaid text grammar, guards containing `()`, `<`, and `&&` round-trip untouched. The one place author-controlled text (labels, step names, guards) reaches the DOM is the tap-to-inspect detail panel, which HTML-escapes it before insertion. Cytoscape and dagre load only on that page.

**Auto-refresh:** the polling refresh updates the list/stats region with a Turbo **morph** stream (`<turbo-stream action="update" method="morph">`) rather than replacing its `innerHTML`. idiomorph mutates the existing nodes in place, so a table's horizontal scroll and the filter inputs' value, caret, and focus all survive a tick with no manual bookkeeping. The filter text inputs carry `data-cf-poll-preserve`; a `turbo:before-morph-element` listener skips them so an in-progress query is never reset to the last-submitted value. The refresh is scoped to the list/stats region (gated on the `data-poll-region` attribute), so the header and flash toasts are left alone — and the definition graph opts out entirely, since morphing would wipe its live Cytoscape canvas.

## Development

Run a seeded preview locally (compiles the stylesheet, then boots a demo app on `http://localhost:9876/chrono_forge`):

```bash
bin/dev          # PORT=9877 bin/dev to change the port
```

To release: bump `lib/chrono_forge/dashboard/version.rb`, commit, then run:

```bash
bin/release
```

It compiles the stylesheet, refuses to continue on a dirty tree, then runs `rake release` (tests, linter, build, git tag, and push to RubyGems). `rake build` always recompiles `dashboard.css` first, so a release never ships a stale stylesheet. Use `bundle exec rake prepare` on its own to run assets + tests + linter without releasing.
