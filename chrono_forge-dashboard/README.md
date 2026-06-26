# ChronoForge::Dashboard

A mountable Rails engine that provides visibility and operational controls for ChronoForge workflows.

Version: `0.1.0` (early release). The UI and config API may change before `1.0`.

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
  c.polling_interval    = 5     # seconds; the workflow list auto-refreshes via JS. 0 to disable.
  c.page_size           = 50    # workflows per page
  c.long_wait_threshold = 3600  # seconds; wait-state ages above this are flagged
end
```

| Option | Default | Notes |
| --- | --- | --- |
| `polling_interval` | `5` | Seconds between list auto-refreshes. `0` disables polling. |
| `page_size` | `50` | Workflows per page on the index. |
| `long_wait_threshold` | `3600` | Wait-state age in seconds above which a warning is shown. |

## Features

- **Workflow list**: state badges, filter by state/job class/workflow key, stats header showing counts by state
- **Workflow detail**: step replay timeline showing every `durably_execute`, `wait`, `continue_if`, and `durably_repeat` run; repetitions from `durably_repeat` appear nested under their coordination step
- **Context inspector**: JSON tree view of the workflow's persistent context
- **Per-step error logs**: errors attributed to the step and attempt that raised them
- **Periodic-task health**: summary of each `durably_repeat` task (last run, next run, missed executions)
- **Wait-states view**: lists workflows in a wait state, with age flagged if above `long_wait_threshold`
- **Recovery actions**: retry a stalled or failed workflow, force-unlock a stuck running workflow (with a duplicate-execution warning), bulk retry all failed workflows

## Frontend

The dashboard is server-rendered. It serves one CSS file and one JS file directly from the engine. **The host needs no npm, no build step, and no asset-pipeline configuration** — the compiled stylesheet ships with the gem. The JS is dependency-free vanilla. CSP-compatible (no external hosts or inline handlers).

Styles are written with [Tailwind CSS](https://tailwindcss.com) and precompiled into the shipped `dashboard.css`. Contributors editing views or styles rebuild it with the standalone compiler (no Node required):

```bash
bundle exec rake tailwind:build
```

Assets are cache-busted by a content digest, so a gem upgrade is picked up without a hard refresh.

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
