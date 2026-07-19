# Automatic SolidQueue Concurrency Control — Design

Date: 2026-07-19
Status: Approved

## Goal

When `ChronoForge::Executor` is prepended into a job class and SolidQueue's
`limits_concurrency` API is available, apply a per-workflow-key concurrency
limit automatically. This dedups concurrent wake-ups for the same workflow at
*dispatch* time (SolidQueue blocks the conflicting job) instead of at
*execution* time (ChronoForge's `LockStrategy` dropping it with
`ConcurrentExecutionError`), so worker slots stop being burned on no-op passes.
ChronoForge's DB lock remains the correctness backstop; SolidQueue's semaphore
is an efficiency layer on top.

## Behavior

In `ChronoForge::Executor.prepended` (lib/chrono_forge/executor.rb), before the
`class << base` block:

```ruby
if ChronoForge.config.concurrency_control && base.respond_to?(:limits_concurrency)
  base.limits_concurrency(
    key: ->(key, **) { key },
    duration: ChronoForge.config.max_duration + 5.seconds
  )
end
```

- **Semaphore key**: SolidQueue joins the concurrency *group* (defaults to
  `self.class.name`, computed per-instance via `instance_exec`) with the key
  proc's result, producing `"OrderWorkflow/order-123"`. The workflow class is
  therefore part of the key with no custom composition, and it stays correct
  under subclassing — matching how ChronoForge scopes `Workflow` rows by
  `job_class`. (Verified against solid_queue 1.3.1,
  `lib/active_job/concurrency_controls.rb`.)
- **Key proc**: receives the job's arguments via `instance_exec(*arguments)`;
  the workflow key is the sole positional argument on every enqueue path
  (public `perform_later`, continuations, branch-child rekicks), so
  `->(key, **) { key }` is total.
- **`to: 1`, `on_conflict: :block`**: SolidQueue defaults, kept. Blocking is
  load-bearing — `:discard` would drop continuation jobs and strand workflows
  mid-flight. The automatic default must never set `:discard`.
- **`duration: max_duration + 5.seconds`**: replaces SolidQueue's 3-minute
  default. ChronoForge steals locks older than `max_duration`; the semaphore
  strictly outliving that threshold means SolidQueue never releases a blocked
  job while ChronoForge still considers the lock live. The 5-second buffer
  avoids an exact-tie race between the two expiries.
- **Capability gate**: `respond_to?(:limits_concurrency)` — true when
  solid_queue is loaded (and future-proof for the API's upstreaming into
  Active Job). On any other adapter the block is skipped and nothing changes.

## Configuration

One new `Configuration` accessor:

- `concurrency_control` — boolean, default `true`. Set to `false` in the
  `ChronoForge.configure` initializer to disable the automatic default
  engine-wide.

Timing: Rails initializers run before application classes load, so both
`concurrency_control` and `max_duration` are read at their configured values
when workflow classes are defined. Changing config after boot does not
retroactively update already-loaded classes; this is documented, not worked
around.

## Overriding per class

`limits_concurrency` writes plain class attributes; last write wins. A workflow
that declares its own call *after* `prepend ChronoForge::Executor` overwrites
the default entirely — this is the documented way to add cross-key throttling
(`to: N`, custom `group:`) or a different duration. No skip-if-already-set
logic: prepend-line-first is the overwhelmingly standard layout, and the
override story is simpler to reason about as "your call wins if it comes
after the prepend".

## Out of scope

- Cross-key/class-wide throttling defaults (`to: N`) — users declare their own
  `limits_concurrency` for that.
- Concurrency limits for `BranchMergeJob` / `CleanupJob` (separate, lightweight
  classes).
- Any adapter-specific behavior beyond the capability check.

## Testing

Unit tests, no solid_queue dependency required:

- Stub module defining `limits_concurrency(**opts)` that records its arguments;
  build an anonymous ActiveJob subclass extending it, prepend
  `ChronoForge::Executor`, assert the call was made with the expected key proc
  and `duration == max_duration + 5.seconds`.
- With `config.concurrency_control = false`: assert no call.
- Class not responding to `limits_concurrency`: assert prepend succeeds and no
  error is raised.
- Key proc: `instance_exec`-style invocation with `("order-123", foo: 1)`
  returns `"order-123"`.
- Optional (dev-only gem group): with real solid_queue loaded, assert a job
  instance's `concurrency_key` is `"<ClassName>/<key>"`.

## Documentation

README gains a "SolidQueue" section: what the default does, the duration
alignment rationale, the warning against `on_conflict: :discard`, and how to
override per class or disable globally.
