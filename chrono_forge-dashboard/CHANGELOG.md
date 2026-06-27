# Changelog

All notable changes to `chrono_forge-dashboard` are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.1.0] - unreleased

Initial release — a free, mountable, server-rendered dashboard for ChronoForge workflows. No host asset pipeline, no schema changes, and no new indexes on hot tables.

### Added

- **Mountable engine** with **fail-closed authentication** — HTTP Basic, a custom hook, or explicit `:none`; mounting without configuring any raises `AuthenticationNotConfigured`.
- **Workflow list** — state badges, keyset (cursor) pagination, capped index-only state counts, and filtering by state / job class (prefix) / key (prefix) / date. Idle workflows parked on a future-dated wait render as **scheduled** rather than "idle".
- **Workflow detail** — a step-replay timeline decoded from execution logs (kind, status, attempts, duration, relative times) with **error logs inlined on the step that produced them** (class, attempt, message, expandable backtrace); periodic-task health; a typed context inspector; and arguments.
- **Recovery actions** — retry (`retry_later`, guarded), force-unlock (with a duplicate-execution warning), and bulk retry of failed + stalled. CSRF- and auth-protected, with a floating auto-dismissing toast.
- **`durably_repeat` repetitions** — iteration runs are collapsed in the timeline into a summary ("N iterations · M catch-up tombstones · last run …") that links to a dedicated, keyset-paginated repetitions page; failed runs are labeled "tombstone" (normal catch-up mechanics), with a "Late by" column (scheduled vs actual start).
- **Waiting page** — leads with the **oldest unresolved `continue_if` (event) wait per class**, the silent stall a webhook-that-never-arrives causes; bounded scan over the oldest idle workflows.
- **Analytics** (own pages, off the hot path) — workflow-level completion rate, failure rate, average duration, and daily throughput over a 24h/7d/30d window; top error classes; and per-class current queue-health counts. Linked per-class from the workflow detail.
- **Scale-aware data access** — keyset pagination (no `OFFSET`/`COUNT(*)`), capped counts, index-friendly windowed aggregation, and bounded scans with visible "showing N" notes. Workflow-level failure rates never count `durably_repeat` catch-up tombstones, with UI notes making the distinction explicit.
- **Frontend** — server-rendered ERB plus one engine-served CSS (Tailwind, precompiled via the standalone CLI) and one vanilla JS file; CSP-friendly (no inline scripts, class-based bar widths), with content-digest asset cache-busting.
