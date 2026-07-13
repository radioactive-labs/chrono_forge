# Changelog

All notable changes to `chrono_forge-dashboard` are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.3.0] - 2026-07-13

### Features

- Turbo-driven refresh + triage-first redesign + reap action ([#14](https://github.com/radioactive-labs/chrono_forge/issues/14))

## [0.2.0] - 2026-07-04

### Bug Fixes

- Preserve filter input and focus across polling refresh
- Converge merges promptly via drain-ETA cadence and never-started-count rekick ([#12](https://github.com/radioactive-labs/chrono_forge/issues/12))
- Overlay/analyzer correctness, detail-panel XSS, and UX polish

### Documentation

- Refresh dashboard screenshots, badges; fix upgrade note and API reference
- Restructure READMEs — promote branches, refine cadence note, dashboard cross-link

### Features

- Hide branch children by default with a filter toggle
- Blocked filter on the index + state dots on branch chips
- Surface merge poll schedule on the branches panel
- Workflow definition graph with static DAG and live run overlay ([#13](https://github.com/radioactive-labs/chrono_forge/issues/13))

### Miscellaneous Tasks

- Replace bin/release with per-gem rake release flow

### Styling

- Apply standardrb blank-line formatting to existing files

## [0.1.0] - 2026-06-27

Initial release — a free, mountable, server-rendered dashboard for ChronoForge workflows. Requires `chrono_forge >= 0.10.0` (for the branches feature and the `durably_repeat` fast-forward catch-up it surfaces). Adds no migrations of its own, no host asset pipeline, and no new indexes on hot tables (branch views read the core's `parent_execution_log_id` index).

### Added

- **Mountable engine** with **fail-closed authentication** — HTTP Basic, a custom hook, or explicit `:none`; mounting without configuring any raises `AuthenticationNotConfigured`.
- **Workflow list** — state badges, keyset (cursor) pagination, capped index-only state counts, and filtering by state / job class (prefix) / key (prefix) / date. Idle workflows parked on a future-dated wait render as **scheduled** rather than "idle".
- **Workflow detail** — a step-replay timeline decoded from execution logs (kind, status, attempts, duration, relative times) with **error logs inlined on the step that produced them** (class, attempt, message, expandable backtrace); periodic-task health; a typed context inspector; and arguments.
- **Recovery actions** — retry (`retry_later`, guarded), force-unlock (with a duplicate-execution warning), bulk retry of failed + stalled, **Resume** (re-enqueue an idle/parked workflow — recovers a dropped wait or merge poll), a **resume poller** action on an overdue branch merge, and per-branch bulk retry of blocked children. CSRF- and auth-protected, with a floating auto-dismissing toast.
- **Branch views** — for workflows that fan out into concurrent sub-workflows (`spawn` / `spawn_each` / `merge_branches`): a per-branch panel on the parent (dispatched / pending / blocked counts, merge state, and **dropped-poller detection** that flags a branch whose `BranchMergeJob` poll is overdue), a parent breadcrumb, a keyset-paginated children drill-down defaulting to the **blocked** (failed + stalled) triage subset, and an in-flight merges list (the durable `BranchMergeJob` records).
- **`durably_repeat` repetitions** — iteration runs are collapsed in the timeline into a summary ("N iterations · M catch-up ticks skipped · last run …") that links to a dedicated, keyset-paginated repetitions page. Expired per-tick catch-up runs are labeled "tombstone"; a fast-forward catch-up summary row (`metadata["fast_forwarded"]`) renders as "caught up ×N" — counted as its N skipped ticks (in the roll-up and the periodic "Missed" count), not as a spurious failure — alongside a "Late by" column (scheduled vs actual start).
- **Waiting page** — leads with the **oldest unresolved `continue_if` (event) wait per class**, the silent stall a webhook-that-never-arrives causes; bounded scan over the oldest idle workflows.
- **Analytics** (own pages, off the hot path) — workflow-level completion rate, failure rate, average duration, and daily throughput over a 24h/7d/30d window; top error classes; and per-class current queue-health counts. Linked per-class from the workflow detail.
- **Display & refresh controls** — a nav toggle for relative vs absolute timestamps (the other form on hover) and an auto-refresh control (pause + interval), both cookie-persisted per viewer; a configurable `polling_interval_options` set; durations scaled to the two most-significant units (seconds → days); and a **Next run** column showing a scheduled workflow's next wake. Live polling preserves horizontal table-scroll position across refreshes.
- **Scale-aware data access** — keyset pagination (no `OFFSET`/`COUNT(*)`), capped counts, index-friendly windowed aggregation, and bounded scans with visible "showing N" notes. Workflow-level failure rates never count `durably_repeat` catch-up runs, with UI notes making the distinction explicit.
- **Frontend** — server-rendered ERB plus one engine-served CSS (Tailwind, precompiled via the standalone CLI) and one vanilla JS file; CSP-friendly (no inline scripts, class-based bar widths), with content-digest asset cache-busting.
