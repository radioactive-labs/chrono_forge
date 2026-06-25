# Reserved-keyword guard + keywords-only enqueue contract

Date: 2026-06-25
Status: Approved (design)

## Problem

`ChronoForge::Executor#perform` reserves several keyword parameters for internal
plumbing:

```ruby
def perform(key, attempt: 0, retry_counts: {}, retry_workflow: false, options: {}, **kwargs)
```

Anything not named here lands in `**kwargs`, is persisted on the `Workflow` row,
and is replayed to the user's job body via `super(**workflow.kwargs.symbolize_keys)`
(`executor.rb:100`).

Two problems follow from the current public enqueue surface
(`perform_now`/`perform_later`), which only validate that `key` is a String:

1. **Silent collision.** A user calling `MyJob.perform_later("k", attempt: 5)`
   silently hijacks the internal retry counter instead of passing their own
   argument. Same risk for `retry_counts` and `retry_workflow`.
2. **No positional contract.** Extra positional arguments produce Ruby's generic
   `wrong number of arguments` error rather than a contract-specific message —
   even though the executor only ever replays kwargs (keyword-only) to the job
   body, so positionals beyond `key` can never work.

## Decisions (settled with maintainer)

- **Public keyword surface:** `key` (required, first positional), `options`
  (free-form metadata bag), and user `**kwargs`. Nothing else.
- **`options` is unstructured.** The framework defines **zero** recognized option
  keys. `options` is written to `workflow.options` (`executor.rb:159`) and only
  ever read back by callers (`workflow.options`); no key in it drives behavior.
- **Reserved keys (rejected on the public path):** `attempt`, `retry_counts`,
  `retry_workflow`. These are internal threading params; users have no legitimate
  reason to pass them.
- **`retry_workflow` is internal**, reached only through the `retry_now` /
  `retry_later` helpers — not by passing the flag directly.
- **Keywords-only:** exactly one positional (`key`); everything else must be a
  keyword, enforced with a clear, contract-specific error.
- **No job-signature validation.** We do *not* introspect the job's `perform`
  parameters to validate unknown/missing kwargs. Out of scope; mismatches still
  surface at execution time as today.

## Mechanism: how internal calls bypass the guard

The split between "framework may pass reserved keys" and "users may not" rests on
an ActiveJob implementation detail, confirmed on ActiveJob 7.1.3.4:

> `ActiveJob::ConfiguredJob` (returned by `.set(...)`) defines its own
> `perform_now` / `perform_later` that build a fresh job instance and call the
> **instance-level** enqueue path. They do **not** dispatch through the
> **class-level** `perform_*` override.

Therefore any enqueue routed through `.set(...)` bypasses the guard:

- All framework continuations already use `.set(wait: …).perform_later(key, …)`
  (`executor.rb:138`, `wait.rb`, `wait_until.rb`, `durably_repeat.rb`,
  `durably_execute.rb`) — their `attempt:`/`retry_counts:`/`wait_condition:`
  ride through untouched.
- `retry_now` / `retry_later` are rewritten to enqueue via `set.perform_*`,
  legitimately injecting `retry_workflow: true` past the guard.

This dependency is non-obvious and now load-bearing, so it is documented inline
at the guard.

## Design

All changes land in `lib/chrono_forge/executor.rb`, in the `class << base` block,
plus one module-level constant. ~30 lines. No schema or behavior changes
elsewhere.

### 1. Reserved-key constant (module level, near `STEP_NAME_DELIMITER`)

```ruby
# Keyword args ChronoForge threads through job args internally. Users must not
# pass these to perform_now/perform_later; the framework injects them via
# `.set(...)` continuations, whose ConfiguredJob proxy bypasses the class-level
# guard below.
RESERVED_KWARGS = %i[attempt retry_counts retry_workflow].freeze
```

### 2. Public guards — `perform_now` / `perform_later`

```ruby
def perform_now(key, *extra, **kwargs)
  __validate_enqueue!(key, extra, kwargs)
  super(key, **kwargs)
end

def perform_later(key, *extra, **kwargs)
  __validate_enqueue!(key, extra, kwargs)
  super(key, **kwargs)
end

private

def __validate_enqueue!(key, extra, kwargs)
  unless key.is_a?(String)
    raise ArgumentError, "Workflow key must be a string as the first argument"
  end
  unless extra.empty?
    raise ArgumentError, "ChronoForge workflows accept only `key` positionally; " \
      "pass everything else as keywords (got #{extra.size} extra positional arg(s))"
  end
  reserved = kwargs.keys & RESERVED_KWARGS
  if reserved.any?
    raise ArgumentError,
      "#{reserved.join(", ")} #{reserved.one? ? "is a reserved" : "are reserved"} " \
      "ChronoForge keyword(s) and cannot be passed to perform_now/perform_later"
  end
end
```

`*extra` exists solely to catch stray positionals and produce the clear error;
after validation it is always empty and discarded (only `super(key, **kwargs)`
is forwarded).

### 3. Retry helpers — route past the guard

```ruby
def retry_now(key, **kwargs)
  __validate_enqueue!(key, [], kwargs)
  set.perform_now(key, retry_workflow: true, **kwargs)
end

def retry_later(key, **kwargs)
  __validate_enqueue!(key, [], kwargs)
  set.perform_later(key, retry_workflow: true, **kwargs)
end
```

They still validate the *user's* kwargs (rejecting any reserved key the user
supplied), then inject `retry_workflow: true` through the `ConfiguredJob` bypass.

### 4. Framework continuations — unchanged

`executor.rb:138`, `wait.rb`, `wait_until.rb`, `durably_repeat.rb`,
`durably_execute.rb` already enqueue via `.set(...)`. No change required.

## Scope / caveats

- **Executor-only.** The guard lives in the `Executor`-prepended singleton.
  `ChronoForge::CleanupJob` is a plain `ActiveJob::Base` and is unaffected
  (its `perform_now(older_than_days: …)` / arg-less `perform_later` keep working).
- **Backward compatible.** A full scan of `lib/` and `test/` found no call site
  passing a second positional and no user call passing a reserved key, so the
  existing suite passes unchanged.
- **`wait_condition`** (internal kwarg in `wait_until`) is intentionally *not*
  added to `RESERVED_KWARGS`: it only ever travels via `.set(...)` and so never
  reaches the guard. Adding it later is a harmless one-line hygiene change if
  desired.

## Testing (TDD)

New tests (Executor-prepended job):

1. `perform_later` / `perform_now` raise `ArgumentError` when passed `attempt:`,
   `retry_counts:`, or `retry_workflow:` — and the message names the key(s).
2. `perform_later` / `perform_now` raise `ArgumentError` with the contract
   message when passed a second positional argument.
3. `perform_later("k", kwarg: "x", options: {a: 1})` still enqueues; `options`
   and user kwargs reach the workflow (`workflow.options`, `workflow.kwargs`).
4. `retry_now` / `retry_later` still unlock-and-continue a stalled workflow
   (existing behavior preserved), and reject reserved keys passed by the caller.
5. Non-String `key` still raises (regression guard for existing behavior).
