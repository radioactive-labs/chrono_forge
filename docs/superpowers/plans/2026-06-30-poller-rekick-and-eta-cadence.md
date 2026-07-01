# BranchMergeJob: debounced drain-aware rekick + ETA poll cadence

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two `BranchMergeJob` defects surfaced by the fan-out scale test: (1) `rekick_dropped_jobs` re-enqueues healthy children that are merely deep in a still-draining queue (and can re-rekick the same child every poll), and (2) the count-based poll cadence saturates at `max_interval` exactly when a fast-draining backlog is about to finish, leaving the parent un-woken for up to 5 minutes after the last child completes.

**Architecture:** Both defects come from using backlog *size* as a proxy for time/health. The poller already computes a per-branch `pending` count each poll and persists it in the branch-log metadata; we make that the shared signal for both fixes.
- **Rekick (Fix 1):** gate rekick on the **pending delta** — a branch whose `pending` dropped since its previous poll is actively draining, so its idle never-started children are queued, not dropped. `child.touch` on a successful rekick debounces re-rekicks (each child at most once per `REKICK_AFTER`). Rekick activity is stamped on the branch-log metadata for the dashboard. No new queries, no new indexes.
- **Cadence (Fix 2):** replace `progressing × FACTOR` with estimated time-to-drain — `(pending / measured_rate) × ETA_FRACTION`, clamped `[min, max]` — using the **uncapped** `pending` and the prior poll's persisted `pending`/timestamp. When no completion is observed this interval, fall back on `motion`: a **running** child holds the responsive floor (it's executing and will finish — no wake-latency regression for slow/low-fan-out children); only a **dispatched-but-unpicked** child (queued/rekicked straggler that may never be picked up) backs off exponentially (floor → … → max); nothing progressing → `max` backstop. `sealed?` and the motion probes are EXISTS; the only per-poll count is the single branch-scoped `pending`. The measured drain `rate` (children/s) and `eta_seconds` are persisted on the branch-log metadata — free (already computed for cadence, no extra query), giving the dashboard live throughput/ETA without the aggregate scans the scale-aware design avoids.

**Tech Stack:** Ruby, ActiveJob, ActiveRecord, Minitest (`ActiveJob::TestCase`), Combustion test harness.

**User Verification:** NO — no user verification required.

---

## Background — the two root causes

`lib/chrono_forge/branch_merge_job.rb` today:

- **Cadence:** `reschedule_delay(progressing, min, max)` = `(progressing * FACTOR).clamp(min, max)`, `FACTOR = 0.06`. `progressing` is a count capped at `CAP = 5000` (`BranchProbe.progressing(id).limit(CAP).count`), so it saturates → `(5000 * 0.06) = 300` → always `max_interval` while a large backlog exists. It polls *slowest* right when a fast-draining backlog is about to finish, so the parent wake overshoots by up to `max_interval` (20k drains in 88s but the parent isn't woken until ~310s; 500k finishes but seals up to 5 min later).
- **`pending` is capped too** (`incomplete(id).limit(CAP).count`), which is why an ETA can't just reuse it: above `CAP` it reads a flat `5000`, so `pending / rate` is meaningless and we're blind to how close we are. Fix 2 **uncaps** `pending` — a single branch-scoped index count (`WHERE parent_execution_log_id = ? AND state <> completed`, served by the existing `[parent_execution_log_id, state]` index), run once per poll (~7 polls for 20k, ~15 for 500k — a background cost, not a hot-path or per-child one).
- **Rekick:** `rekick_dropped_jobs` re-enqueues children that are `idle`, `started_at: nil`, `updated_at < REKICK_AFTER.ago` — which also matches a healthy child waiting in a backlog whose queue wait exceeds `REKICK_AFTER` (first bites at N ≥ 100k per the scale doc). Worse, `perform_later` does not touch the child row, so a child that's been rekicked but not yet picked up stays stale and is **re-rekicked every poll**, piling up duplicate jobs.

`lib/chrono_forge/branch_probe.rb`:
- `incomplete`, `progressing`, `sealed?`, `done?` — `incomplete` is a relation; callers currently add `.limit(CAP).count`. Fix uses `incomplete(id).count` (uncapped). Adds `running?(id)` / `dispatched?(id)` EXISTS predicates for the cadence's `motion` signal; `progressing` stays (still a valid query + tested) but the poller no longer calls it.

### Design decisions locked in during review

- **Drain signal = pending delta, not a query.** `pending < prev_pending` (per branch) means the branch drained since its last poll ≈ a child completed within the poll window (≤ `max_interval` = `REKICK_AFTER`). No `started_at`/`completed_at` query, so **no `started_at` index** — which we deliberately avoid, since `chrono_forge_workflows` is the write-hot table and the scale doc pins the ceiling at single-Postgres fsync throughput. The existing `[parent_execution_log_id, state]` index serves every poller query.
- **First poll (no `prev_pending`) does NOT gate on draining** — it falls through to the per-child staleness filter (`updated_at < REKICK_AFTER.ago`), which already spares freshly-dispatched children. So a genuinely-dropped stale child is still recovered on a cold first poll.
- **Missed signal is harmless:** the pending-delta gate can't see "picked up but not yet completed" (all-slow-children). Worst case a queued sibling is rekicked once — but there's no free worker, so it's a lock-guard-rejected duplicate, debounced by `touch`. Not worth a query to prevent.
- **Cadence backoff is motion-aware (review concern #1).** When no completion is observed this interval, a `:running` child holds the responsive floor (it's executing — backing off would wake the parent late for a slow/low-fan-out child, a regression vs. today's floor); only a `:dispatched`-but-unpicked child (queued/rekicked straggler) backs off exponentially; `:none` (blocked/waiting) goes straight to `max`. A long-running child therefore polls at the floor exactly as today — no new spin, no regression.

## File structure

- `lib/chrono_forge/branch_merge_job.rb` — Fix 1 (`rekick_dropped_jobs` gate + `touch` + counts; `record_poll!` rekick stats; `superseded?(logs, …)`; uncapped `pending`; load logs once) and Fix 2 (`perform` cadence wiring + `motion`; `reschedule_delay` rewrite; remove `FACTOR`/`CAP`, add `ETA_FRACTION`; `record_poll!` `interval` + `rate`/`eta_seconds`).
- `lib/chrono_forge/branch_probe.rb` — add `running?(id)` / `dispatched?(id)` EXISTS predicates for the cadence's `motion` signal.
- `lib/chrono_forge/executor/methods/merge_branches.rb` — update the one stale `FACTOR` comment (~line 19).
- `test/branch_merge_job_test.rb` — new rekick tests (draining-suppress, quiet-rekicks, debounce, metadata); rewritten cadence unit tests (motion); second-poll throughput/ETA + running-holds-floor integration tests.
- `docs/fanout-scale-test.md` — replace the "needs a caveat" framing with a "Poller behavior" note (drain-aware rekick + ETA cadence, corrected 500k cadence).
- `chrono_forge-dashboard/…` (separate package) — render the persisted `rate`/`eta_seconds` on the merges list (`branches_presenter.rb` + `_branches.html.erb`).

Tasks are ordered Fix 1 (which lands the shared foundation: load-logs-once + uncapped `pending`) then Fix 2 (cadence + throughput persistence), then the doc, then the dashboard rendering (Task 4, cross-package).

---

### Task 1: Debounced drain-aware rekick + observability (Fix 1)

**Goal:** Rekick a never-started child only when its branch is NOT draining (pending didn't drop since the last poll), at most once per `REKICK_AFTER` (touch debounce), and record rekick activity on the branch-log metadata. Lands the shared foundation: load logs once, uncapped `pending`, `superseded?(logs, …)`.

**Files:**
- Modify: `lib/chrono_forge/branch_merge_job.rb`
- Test: `test/branch_merge_job_test.rb`

**Acceptance Criteria:**
- [ ] A branch whose `pending` dropped since its prior poll does NOT rekick stale idle children.
- [ ] A branch with unchanged `pending` (and a cold first poll) STILL rekicks a stale never-started child.
- [ ] The same child is not rekicked twice within `REKICK_AFTER` (touch debounce).
- [ ] Branch-log metadata records `rekicked` (this poll), `rekick_total`, `last_rekick_at`.
- [ ] All pre-existing tests pass.

**Verify:** `bundle exec ruby -I test test/branch_merge_job_test.rb` → all green.

**Steps:**

- [ ] **Step 1: Write the failing tests** (append to `test/branch_merge_job_test.rb`, before the final `end`)

```ruby
  # Fix 1: pending dropped since the prior poll => branch is draining => a stale
  # idle never-started child is queued behind the drain, not dropped. No rekick.
  def test_does_not_rekick_while_branch_is_draining
    @log.update!(metadata: {"poll" => {"pending" => 5, "last_polled_at" => 30.seconds.ago.iso8601, "polls" => 1}})
    stale = child!(state: :idle, started_at: nil) # pending now = 1 < prior 5 => draining
    stale.update_column(:updated_at, 10.minutes.ago)
    assert_no_enqueued_jobs(only: NoopChild) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  # Pending unchanged since the prior poll (branch gone quiet) => a genuinely
  # dropped, stale never-started child IS rekicked.
  def test_rekicks_when_branch_has_gone_quiet
    @log.update!(metadata: {"poll" => {"pending" => 1, "last_polled_at" => 30.seconds.ago.iso8601, "polls" => 1}})
    stale = child!(state: :idle, started_at: nil) # pending now = 1 == prior 1 => not draining
    stale.update_column(:updated_at, 10.minutes.ago)
    assert_enqueued_with(job: NoopChild, args: [stale.key]) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  # Debounce: touch on a successful rekick bumps updated_at, so the same child is
  # not re-rekicked on the very next poll (it must go stale again first).
  def test_does_not_rekick_same_child_twice_in_debounce_window
    stale = child!(state: :idle, started_at: nil)
    stale.update_column(:updated_at, 10.minutes.ago)
    assert_enqueued_with(job: NoopChild, args: [stale.key]) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
    # Second poll: touch made updated_at fresh => not eligible => no re-rekick.
    assert_no_enqueued_jobs(only: NoopChild) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  # Observability: rekick activity is stamped on the branch-log metadata for the
  # dashboard (ActiveJob can't be queried for the scheduled poller).
  def test_records_rekick_stats_on_branch_log
    stale = child!(state: :idle, started_at: nil)
    stale.update_column(:updated_at, 10.minutes.ago)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)

    poll = @log.reload.metadata["poll"]
    assert_equal 1, poll["rekicked"]
    assert_equal 1, poll["rekick_total"]
    assert poll["last_rekick_at"], "last_rekick_at should be set when a rekick happened"
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec ruby -I test test/branch_merge_job_test.rb -n "/draining|gone_quiet|debounce|rekick_stats/"`
Expected: `draining` FAILS (rekicks today — no gate), `debounce` FAILS (re-rekicks — no touch), `rekick_stats` FAILS (no metadata). `gone_quiet` may already pass.

- [ ] **Step 3: Load logs once, uncap `pending`, thread rekick counts** (`lib/chrono_forge/branch_merge_job.rb`, `perform`)

Replace the top of `perform` and the pre-cadence section (leave the `reschedule_delay(progressing, …)` cadence line as-is for now — Task 2 rewrites it):

```ruby
    def perform(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval, token = nil)
      raise ArgumentError, "branch_log_ids must not be empty" if branch_log_ids.empty?

      logs = ExecutionLog.where(id: branch_log_ids).to_a
      return if superseded?(logs, token)

      prev_pending_by_branch = logs.to_h { |l| [l.id, l.metadata&.dig("poll", "pending")] }
      pending_by_branch = branch_log_ids.to_h { |id| [id, BranchProbe.incomplete(id).count] }
      sealed_by_branch = branch_log_ids.to_h { |id| [id, BranchProbe.sealed?(id)] }
      pending = pending_by_branch.values.sum
      sealed = sealed_by_branch.values.all?

      if sealed && pending.zero?
        record_poll!(pending_by_branch, sealed_by_branch, token, next_poll_at: nil, rekicked_by_branch: {})
        parent_job_class.constantize.perform_later(parent_key)
        return
      end

      rekicked_by_branch = rekick_dropped_jobs(branch_log_ids, pending_by_branch, prev_pending_by_branch)

      progressing = branch_log_ids.sum { |id| BranchProbe.progressing(id).limit(CAP).count }
      delay = reschedule_delay(progressing, min_interval, max_interval)
      record_poll!(pending_by_branch, sealed_by_branch, token,
        next_poll_at: delay.seconds.from_now, rekicked_by_branch: rekicked_by_branch)
      self.class.set(wait: delay.seconds)
        .perform_later(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval, token)
    end
```

- [ ] **Step 4: Refactor `superseded?` to take loaded logs** (`lib/chrono_forge/branch_merge_job.rb`)

```ruby
    def superseded?(logs, token)
      logs.empty? || logs.any? { |log| log.metadata&.dig("poll_token") != token }
    end
```

- [ ] **Step 5: Gate rekick on the pending delta, touch on success, return counts** (`lib/chrono_forge/branch_merge_job.rb`, `rekick_dropped_jobs`)

Rewrite the method (keep the existing rescue/log body verbatim inside the block):

```ruby
    def rekick_dropped_jobs(branch_log_ids, pending_by_branch, prev_pending_by_branch)
      cutoff = REKICK_AFTER.ago
      branch_log_ids.to_h do |id|
        # Skip a branch that drained since its last poll: its pending dropped, so
        # the queue is moving and idle never-started children are just in line,
        # not dropped. With no prior sample (cold poll) we don't gate — the
        # per-child staleness filter below still spares freshly-dispatched rows.
        prev = prev_pending_by_branch[id]
        next [id, 0] if prev && pending_by_branch[id] < prev

        count = 0
        Workflow.where(parent_execution_log_id: id, state: Workflow.states[:idle], started_at: nil)
          .where("updated_at < ?", cutoff)
          .limit(REKICK_BATCH)
          .find_each do |child|
            # Intentionally uses the GUARDED perform_later (single-child path),
            # unlike the bulk perform_all_later bypass in dispatch_children.
            #
            # Rekick is best-effort recovery, so one bad child must never sink the
            # poll: a raise here (e.g. cross-version kwarg drift failing the enqueue
            # guard) would abort the whole run and — since it isn't a transient AR
            # error — dead-letter the poller, orphaning every healthy sibling. Catch
            # per child, log, and let the next poll retry it (it's still idle+stale).
            child.job_klass.perform_later(child.key, **child.kwargs.symbolize_keys)
            # Debounce: bump updated_at so this child isn't re-rekicked until it's
            # been unstarted for another REKICK_AFTER — one redelivery window for a
            # worker to pick it up. Only on a SUCCESSFUL enqueue; a rescued failure
            # leaves it stale so the next poll retries.
            child.touch
            count += 1
          rescue => e
            Rails.logger.error do
              "ChronoForge:BranchMergeJob rekick failed for child #{child.key}: " \
              "#{e.class}: #{e.message}"
            end
          end
        [id, count]
      end
    end
```

- [ ] **Step 6: Record rekick stats in `record_poll!`** (`lib/chrono_forge/branch_merge_job.rb`)

Add the `rekicked_by_branch:` keyword and write the three fields (keep the existing lock/token-recheck):

```ruby
    def record_poll!(pending_by_branch, sealed_by_branch, token, next_poll_at:, rekicked_by_branch:)
      now = Time.current
      ExecutionLog.where(id: pending_by_branch.keys).find_each do |log|
        log.with_lock do
          meta = log.metadata || {}
          next unless meta["poll_token"] == token
          prev = meta["poll"] || {}
          n = rekicked_by_branch[log.id].to_i
          meta["poll"] = {
            "last_polled_at" => now.iso8601,
            "next_poll_at" => next_poll_at&.iso8601,
            "pending" => pending_by_branch[log.id],
            "sealed" => sealed_by_branch[log.id],
            "polls" => prev["polls"].to_i + 1,
            "rekicked" => n,
            "rekick_total" => prev["rekick_total"].to_i + n,
            "last_rekick_at" => (n.positive? ? now.iso8601 : prev["last_rekick_at"])
          }
          log.update!(metadata: meta)
        end
      end
    end
```

- [ ] **Step 7: Run the rekick + poll suite**

Run: `bundle exec ruby -I test test/branch_merge_job_test.rb -n "/rekick|draining|gone_quiet|debounce|poll/"`
Expected: all PASS, including pre-existing `test_rekicks_never_started_child`, `test_does_not_rekick_recent_idle_child`, `test_does_not_rekick_failed_or_stalled_children`, `test_does_not_rekick_waiting_child`, `test_rekick_is_capped_at_batch_size`, `test_rekicked_child_runs_to_completion`, `test_records_poll_state_on_branch_log`, `test_poll_state_preserves_existing_branch_metadata`, `test_poll_count_increments_across_polls`, token tests.

- [ ] **Step 8: Run the full file (cadence still old, should still pass)**

Run: `bundle exec ruby -I test test/branch_merge_job_test.rb`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/chrono_forge/branch_merge_job.rb test/branch_merge_job_test.rb
git commit -m "fix(branch): gate rekick on pending-delta drain signal, debounce with touch"
```

---

### Task 2: ETA + exponential-backoff poll cadence (Fix 2)

**Goal:** Drive the reschedule delay from estimated time-to-drain (measured from the prior poll's uncapped `pending`), clamped `[min, max]`. When nothing completed this interval, use `motion`: a **running** child holds the floor (no wake-latency regression), a **dispatched**-but-unpicked straggler backs off exponentially (floor → … → max), **none** → `max`. A fast-draining backlog is detected within ~`min_interval` of finishing. Persist the measured `rate` (children/s) + `eta_seconds` per branch for the dashboard.

**Files:**
- Modify: `lib/chrono_forge/branch_merge_job.rb` (`perform` cadence wiring + `motion`; `reschedule_delay` (takes `rate`, `motion`); remove `FACTOR`/`CAP`, add `ETA_FRACTION`; `record_poll!` `interval` + `rate`/`eta_seconds`)
- Modify: `lib/chrono_forge/branch_probe.rb` (add `running?`/`dispatched?`)
- Modify: `lib/chrono_forge/executor/methods/merge_branches.rb` (stale `FACTOR` comment)
- Test: `test/branch_merge_job_test.rb`

**Acceptance Criteria:**
- [ ] Positive measured drain rate → delay ≈ `(pending / rate) × ETA_FRACTION`, clamped.
- [ ] No completion + a **running** child → holds `min_interval` (never backs off — anti-regression guard).
- [ ] No completion + only a **dispatched**-but-unpicked child → exponential backoff from `min` (doubles per empty poll), capped at `max`.
- [ ] Nothing progressing → `max_interval`.
- [ ] Seeded second poll over a real branch applies the ETA-scaled delay AND records `rate` > 0 + `eta_seconds` (integration).
- [ ] All pre-existing cadence/poll/token tests pass (two pure `reschedule_delay` unit tests rewritten).

**Verify:** `bundle exec ruby -I test test/branch_merge_job_test.rb` then `bundle exec rake test TEST="test/branch_*_test.rb"`.

**Steps:**

- [ ] **Step 1: Rewrite the two unit tests + add integration tests** (`test/branch_merge_job_test.rb`)

Delete `test_reschedule_delay_scales_and_clamps` and `test_reschedule_delay_uses_max_when_nothing_progresses` and replace with:

```ruby
  # Cadence: reschedule_delay(pending, rate, motion, prev_delay, min, max).
  # `rate` is children/s (0 unless the branch drained since the prior poll); `motion`
  # is :running | :dispatched | :none. Positive rate => ETA-scaled delay (motion moot).
  def test_reschedule_delay_scales_with_measured_drain_rate
    job = ChronoForge::BranchMergeJob.new
    # rate 20/s, 800 left => ETA 40s; * 0.5 = 20s.
    assert_in_delta 20, job.send(:reschedule_delay, 800, 20.0, :running, nil, 5, 300), 0.001
  end

  def test_reschedule_delay_clamps_eta_to_max
    job = ChronoForge::BranchMergeJob.new
    # Crawling rate => huge ETA => clamps down to max.
    assert_equal 300, job.send(:reschedule_delay, 100_000, 0.1, :running, nil, 5, 300)
  end

  def test_reschedule_delay_clamps_eta_to_min
    job = ChronoForge::BranchMergeJob.new
    # Nearly drained => tiny ETA => clamps up to the floor.
    assert_equal 5, job.send(:reschedule_delay, 1, 1000.0, :running, nil, 5, 300)
  end

  # A running child produced no completion this interval: HOLD the floor (it's
  # executing and will finish) — never back off, even with a large prior delay.
  # This is the anti-regression guard for slow / low-fan-out children.
  def test_reschedule_delay_running_holds_floor
    job = ChronoForge::BranchMergeJob.new
    assert_equal 5, job.send(:reschedule_delay, 1, 0.0, :running, nil, 5, 300)
    assert_equal 5, job.send(:reschedule_delay, 1, 0.0, :running, 200, 5, 300) # ignores prev_delay
  end

  # Only a dispatched-but-unpicked child left (rate 0, :dispatched): back off
  # exponentially from the floor (no prior delay => start at min; then double).
  def test_reschedule_delay_backs_off_exponentially_for_dispatched_straggler
    job = ChronoForge::BranchMergeJob.new
    assert_equal 5, job.send(:reschedule_delay, 100, 0.0, :dispatched, nil, 5, 300)   # first empty => min
    assert_equal 10, job.send(:reschedule_delay, 100, 0.0, :dispatched, 5, 5, 300)    # doubles
    assert_equal 300, job.send(:reschedule_delay, 100, 0.0, :dispatched, 200, 5, 300) # capped at max
  end

  # Nothing can progress (all blocked/waiting) => straight to the max backstop.
  def test_reschedule_delay_uses_max_when_nothing_progresses
    job = ChronoForge::BranchMergeJob.new
    assert_equal 300, job.send(:reschedule_delay, 100, 0.0, :none, nil, 5, 300)
    assert_equal 300, job.send(:reschedule_delay, 100, 0.0, :none, 200, 5, 300)
  end
```

Add the second-poll integration test before the final `end`:

```ruby
  # Second poll: cadence is driven by the drain rate measured from the first
  # poll's persisted pending, not backlog size — and that rate is persisted as
  # throughput. Seed 50 pending 60s ago, leave 40 incomplete => 10 drained over
  # ~60s ≈ 0.167/s => ETA 240s => * 0.5 => ~120s.
  def test_second_poll_records_throughput_and_uses_it_for_cadence
    @log.update!(metadata: {"poll" => {
      "pending" => 50, "last_polled_at" => 60.seconds.ago.iso8601, "polls" => 1
    }})
    40.times { child!(state: :idle, started_at: nil) } # fresh => not rekicked
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)

    assert_in_delta 120, poll_delay, 8,
      "second poll should schedule at ~ETA*ETA_FRACTION, not a count-based delay"
    poll = @log.reload.metadata["poll"]
    assert_operator poll["rate"], :>, 0, "drain rate (throughput) should be recorded"
    assert poll["eta_seconds"], "eta_seconds should be recorded while draining"
  end

  # Anti-regression (concern #1): a running child that produced no completion this
  # interval must keep the floor, NOT decay to the prior poll's backoff — otherwise
  # a slow / low-fan-out child wakes the parent up to max_interval late.
  def test_running_child_holds_floor_end_to_end
    @log.update!(metadata: {"poll" => {
      "pending" => 1, "interval" => 40, "last_polled_at" => 30.seconds.ago.iso8601, "polls" => 3
    }})
    child!(state: :running) # pending stays 1 => no drain => rate 0, motion :running
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    assert_in_delta 5, poll_delay, 1,
      "a running child must hold the floor, not decay to the 40s->80s backoff"
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec ruby -I test test/branch_merge_job_test.rb -n "/reschedule_delay|second_poll/"`
Expected: FAIL — old `reschedule_delay` arity (`ArgumentError`) and `ETA_FRACTION` undefined.

- [ ] **Step 3: Swap constants** (`lib/chrono_forge/branch_merge_job.rb`)

Replace the `CAP`/`FACTOR` lines (both now unused — `pending` is uncapped, `progressing` becomes EXISTS) with:

```ruby
    ETA_FRACTION = 0.5   # poll at this fraction of the projected time-to-drain
    REKICK_AFTER = 5.minutes
    REKICK_BATCH = 200   # bound per-run rekicks; later polls handle the rest
```

- [ ] **Step 3b: Add `running?` / `dispatched?` motion probes to `BranchProbe`** (`lib/chrono_forge/branch_probe.rb`)

These split the old `progressing` (running OR dispatched-unstarted) into the two cases the cadence must tell apart. Add after `progressing` (leave `progressing` in place — still a valid query, still covered by `branch_probe_test.rb`; the poller just no longer uses it):

```ruby
    # A child of this branch is actively executing — a live worker will complete
    # it, so the poller can hold its responsive floor rather than backing off.
    def running?(branch_log_id)
      Workflow.where(parent_execution_log_id: branch_log_id, state: Workflow.states[:running]).exists?
    end

    # A child was dispatched but no worker has started it yet (started_at nil). If
    # this is the only motion left, it's a queued/rekicked-but-unpicked straggler
    # (which may never be picked up), NOT active work — so the poller backs off.
    def dispatched?(branch_log_id)
      Workflow.where(parent_execution_log_id: branch_log_id,
        state: Workflow.states[:idle], started_at: nil).exists?
    end
```

- [ ] **Step 4: Wire the cadence in `perform`** (`lib/chrono_forge/branch_merge_job.rb`)

Replace the Task-1 interim cadence block (the `progressing = … limit(CAP) …` / `delay = reschedule_delay(progressing, …)` / `record_poll!(…)` / reschedule lines) with:

```ruby
      # Cadence is driven by ESTIMATED TIME-TO-DRAIN, measured from the prior
      # poll's persisted pending. `motion` (EXISTS probes) is the fallback signal
      # when nothing completed this interval: :running => a live worker is
      # executing a child (hold the floor, it'll finish); :dispatched => the only
      # motion is a queued/rekicked-but-unpicked child (back off exponentially,
      # it may never be picked up); :none => blocked/waiting (max backstop).
      # See reschedule_delay.
      motion = if branch_log_ids.any? { |id| BranchProbe.running?(id) } then :running
      elsif branch_log_ids.any? { |id| BranchProbe.dispatched?(id) } then :dispatched
      else :none
      end
      prior = logs.map { |l| l.metadata&.dig("poll") }
      # Only trust the AGGREGATE prev_pending when every requested branch log is
      # loaded AND carries a prior sample — otherwise `pending` (summed over all
      # branch_log_ids) and prev_pending (over loaded logs) would cover different
      # sets and yield a bogus aggregate rate. Missing/partial => no sample =>
      # bootstrap. Per-branch rate below is independently safe (missing => nil => 0).
      complete_prior = logs.size == branch_log_ids.size && prior.all?
      prev_pending = (prior.sum { |p| p["pending"].to_i } if complete_prior)
      prev_polled_at = prior.filter_map { |p| p && p["last_polled_at"] }.map { |s| Time.zone.parse(s) }.min
      elapsed = prev_polled_at && (Time.current - prev_polled_at)
      prev_delay = prior.filter_map { |p| p && p["interval"] }.max

      # Drain rate = children completed / second since the prior poll — THIS is the
      # throughput surfaced on the dashboard. Per branch for display; aggregated for
      # the ETA. Zero unless the branch actually drained (a no-headway / cold poll).
      # NOTE: the aggregate ETA blurs a heterogeneous multi-branch merge (one branch
      # draining fast, another stalled). Acceptable: automerge is single-branch, and
      # the clamp + per-poll re-estimate bound any skew. Per-branch rate is retained
      # for the dashboard.
      drained = ->(pend, prev) { prev && elapsed && elapsed > 0 && pend < prev }
      rate_by_branch = pending_by_branch.to_h do |id, pend|
        prev = prev_pending_by_branch[id]
        [id, drained.call(pend, prev) ? (prev - pend) / elapsed.to_f : 0.0]
      end
      rate = drained.call(pending, prev_pending) ? (prev_pending - pending) / elapsed.to_f : 0.0

      delay = reschedule_delay(pending, rate, motion, prev_delay, min_interval, max_interval)
      record_poll!(pending_by_branch, sealed_by_branch, token, next_poll_at: delay.seconds.from_now,
        interval: delay, rate_by_branch: rate_by_branch, rekicked_by_branch: rekicked_by_branch)
      self.class.set(wait: delay.seconds)
        .perform_later(parent_key, parent_job_class, branch_log_ids, min_interval, max_interval, token)
```

Also add `interval: nil, rate_by_branch: {}` to the sealed-wake `record_poll!` call:

```ruby
        record_poll!(pending_by_branch, sealed_by_branch, token,
          next_poll_at: nil, interval: nil, rate_by_branch: {}, rekicked_by_branch: {})
```

- [ ] **Step 5: Rewrite `reschedule_delay`** (`lib/chrono_forge/branch_merge_job.rb`)

Replace the whole method + doc comment:

```ruby
    # Adaptive poll cadence driven by ESTIMATED TIME-TO-DRAIN, not backlog size.
    # When the branch-set drained since the last poll we project completion from
    # the measured rate and poll at ETA_FRACTION of it, clamped [min, max]. Because
    # each poll re-estimates against the shrinking remainder, cadence converges
    # geometrically and detects the merge within ~min_interval of the last child
    # finishing — where the old count-based cadence polled SLOWEST (max_interval)
    # exactly when a fast-draining backlog was about to complete.
    #
    # No completion observed this interval — fall back on `motion`:
    #   :running    => a live worker is executing a child; it will finish, so hold
    #                  the responsive floor (this matches today's behaviour and
    #                  avoids waking the parent late for a slow/low-fan-out child).
    #   :dispatched => the only motion is a queued/rekicked-but-unpicked child that
    #                  may never be picked up => exponential backoff from the floor
    #                  (double prev_delay, capped at max), so we catch a quick
    #                  recovery within seconds but don't spin on a dead dispatch.
    #   :none       => nothing can progress (blocked/failed or parked on a wait) =>
    #                  straight to max_interval, the cheap recovery backstop.
    # min_interval <= max_interval is enforced in merge_branches, so clamp is safe.
    # `rate` is children/s measured by the caller (0 => nothing completed since the
    # prior poll / cold poll).
    def reschedule_delay(pending, rate, motion, prev_delay, min_interval, max_interval)
      return (pending / rate * ETA_FRACTION).clamp(min_interval, max_interval) if rate > 0

      case motion
      when :running then min_interval
      when :dispatched then prev_delay ? (prev_delay * 2).clamp(min_interval, max_interval) : min_interval
      else max_interval
      end
    end
```

- [ ] **Step 6: Add `interval:` + `rate_by_branch:` to `record_poll!` and persist throughput** (`lib/chrono_forge/branch_merge_job.rb`)

Update the signature:

```ruby
    def record_poll!(pending_by_branch, sealed_by_branch, token, next_poll_at:, interval:, rate_by_branch:, rekicked_by_branch:)
```

and inside the `with_lock` block, read the per-branch rate and write `interval`/`rate`/`eta_seconds` into the `"poll"` hash (alongside the Task-1 fields):

```ruby
          pend = pending_by_branch[log.id]
          rate = rate_by_branch[log.id].to_f
          meta["poll"] = {
            "last_polled_at" => now.iso8601,
            "next_poll_at" => next_poll_at&.iso8601,
            "interval" => interval,
            "pending" => pend,
            "sealed" => sealed_by_branch[log.id],
            "rate" => rate.round(2),                               # children/s (throughput)
            "eta_seconds" => (rate > 0 ? (pend / rate).round : nil),
            "polls" => prev["polls"].to_i + 1,
            "rekicked" => n,
            "rekick_total" => prev["rekick_total"].to_i + n,
            "last_rekick_at" => (n.positive? ? now.iso8601 : prev["last_rekick_at"])
          }
```

- [ ] **Step 7: Update the stale comment in `merge_branches.rb`** (~line 19)

```ruby
          # Validate cadence here, in the parent, so a misconfiguration fails at the
          # call site instead of deep inside the poller — where the clamp to
          # [min_interval, max_interval] would raise ArgumentError, a non-transient
          # error that dead-letters BranchMergeJob and orphans the parent.
```

- [ ] **Step 8: Run the full file**

Run: `bundle exec ruby -I test test/branch_merge_job_test.rb`
Expected: all PASS — rewritten unit tests, both integration tests, and every pre-existing cadence test. The four first-poll cadence tests still hold under `motion`: `test_blocked_only_branch_backs_off_to_max_interval` (failed+stalled → `:none` → max), `test_waiting_only_branch_backs_off_from_floor` (idle+started_at set → not running, not dispatched → `:none` → max > 5), `test_progressing_child_keeps_responsive_floor` (running child → `:running` → min), `test_blocked_siblings_do_not_slow_a_progressing_child` (running + failed → `:running` → min).

- [ ] **Step 9: Run the broader branch suite**

Run: `bundle exec rake test TEST="test/branch_*_test.rb"` (plus `test/merge_branches_test.rb`, `test/automerge_test.rb`, `test/branch_probe_test.rb`)
Expected: all PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/chrono_forge/branch_merge_job.rb lib/chrono_forge/executor/methods/merge_branches.rb test/branch_merge_job_test.rb
git commit -m "fix(branch): drive poll cadence by estimated drain time with backoff"
```

---

### Task 3: Update the scale-test doc

**Goal:** Replace the "needs a caveat" framing in `docs/fanout-scale-test.md` with a "Poller behavior" note covering drain-aware rekick and the corrected ETA cadence.

**Files:**
- Modify: `docs/fanout-scale-test.md`

**Acceptance Criteria:**
- [ ] Doc no longer implies `REKICK_AFTER` causes spurious rekicks at ≥100k; describes the pending-delta gate + touch debounce and the ETA cadence with the corrected 500k profile.

**Verify:** manual read.

**Steps:**

- [ ] **Step 1: Add a "Poller behavior" section** near the Dashboard / Environment-caveats section of `docs/fanout-scale-test.md`

```markdown
## Poller behavior

`BranchMergeJob` cadence is driven by **estimated time-to-drain** (from the prior
poll's uncapped pending count), not backlog size. For a 500k fan-out draining at
~200/s this is flat `max_interval` (5 min) polling through the long middle, then a
smooth ramp over the final minutes, tightening to `min_interval` (~5s) for the
last few thousand children — so the parent is woken within ~5s of the last child
finishing rather than up to a full `max_interval` late. ~15 cheap polls across the
run, one branch-scoped index count each (`[parent_execution_log_id, state]`); no
new indexes. When nothing completes in an interval the fallback is motion-aware: a
child still running holds the responsive floor (so a slow or single-child branch is
never woken late), a dispatched-but-unpicked straggler backs off exponentially, and
a fully blocked/waiting branch decays to `max_interval` instead of spinning.

Rekick of dropped children is **gated on the pending delta**: a branch whose
pending dropped since its last poll is still draining, so deeply-queued-but-healthy
children are left alone; only a branch that has gone quiet has its never-started
children rekicked, and a `touch` on each rekick debounces it to at most once per
`REKICK_AFTER`. Rekick counts are stamped on the branch-log metadata for the
dashboard.
```

- [ ] **Step 2: Commit**

```bash
git add docs/fanout-scale-test.md
git commit -m "docs: note ETA cadence and debounced drain-aware rekick in scale test"
```

---

### Task 4: Dashboard — live throughput / ETA for in-flight merges

**Goal:** Surface the `rate` (throughput) and `eta_seconds` now persisted by the poller on the merges list of a parent workflow's detail page. Separate package (`chrono_forge-dashboard`); depends on Task 2 shipping the metadata.

**Files (in `chrono_forge-dashboard/`):**
- Modify: `app/presenters/chrono_forge/dashboard/branches_presenter.rb` (extend `Merge` struct + `merges` builder)
- Modify: `app/views/chrono_forge/dashboard/workflows/_branches.html.erb` (render throughput/ETA in the merges section)
- Test: `test/presenters_test.rb` (or `test/branches_test.rb`)

**Acceptance Criteria:**
- [ ] A merging branch with poll `rate`/`eta_seconds` in metadata shows throughput (children/s) and an ETA.
- [ ] Absent/zero rate (cold poll, or a `:merged` merge) renders nothing (no "0/s", no bogus ETA).

**Verify:** `cd chrono_forge-dashboard && bundle exec rake test TEST=test/presenters_test.rb`
(In a fresh worktree, copy the git-ignored working `Gemfile.lock` in first — see [[worktree-gemfile-lock]].)

**Steps:**

- [ ] **Step 1: Write the failing presenter test** (`chrono_forge-dashboard/test/presenters_test.rb`)

Add a test that builds a parent with a `:merging` merge whose target branch log carries `metadata["poll"] = {"rate" => 226.0, "eta_seconds" => 88, "last_polled_at" => …}` and asserts the presenter's `Merge` exposes `rate == 226.0` and `eta_seconds == 88`. (Mirror the existing merge/poll setup already in this file — reuse its parent/branch-log factory helpers.)

- [ ] **Step 2: Run to verify failure**

Run: `cd chrono_forge-dashboard && bundle exec rake test TEST=test/presenters_test.rb`
Expected: FAIL — `Merge` has no `rate`/`eta_seconds` members.

- [ ] **Step 3: Extend the `Merge` struct and builder** (`app/presenters/chrono_forge/dashboard/branches_presenter.rb`)

Add the two members and populate them from the poll hash:

```ruby
      Merge = Struct.new(:names, :state, :started_at, :last_polled_at, :next_poll_at, :polls, :rate, :eta_seconds) do
        def merging? = state == :merging
        def merged? = state == :merged
        def poll_overdue? = merging? && next_poll_at && next_poll_at.past?
        # Throughput is a live gauge — only meaningful while merging and actually draining.
        def throughput? = merging? && rate.to_f > 0
      end
```

and in `merges`, pass the new fields (right after `poll&.dig("polls")`):

```ruby
            poll&.dig("polls"),
            poll&.dig("rate"),
            poll&.dig("eta_seconds")
```

- [ ] **Step 4: Render it** (`app/views/chrono_forge/dashboard/workflows/_branches.html.erb`, in the merges `<% branches.merges.each do |m| %>` block near the poll spans ~line 54–56)

```erb
            <% if m.throughput? %><span title="measured over the last poll interval"><%= number_with_delimiter(m.rate.round) %>/s</span><% end %>
            <% if m.throughput? && m.eta_seconds %><span>ETA <%= cf_duration(m.eta_seconds) %></span><% end %>
```

Use whatever duration helper the dashboard already exposes (`cf_duration`/`distance_of_time_in_words` — grep `app/helpers/chrono_forge/dashboard/dashboard_helper.rb`); if none fits, render `#{m.eta_seconds}s` inline. Match the surrounding `<span>` styling.

- [ ] **Step 5: Run tests + commit**

```bash
cd chrono_forge-dashboard && bundle exec rake test TEST=test/presenters_test.rb
git add app/presenters/chrono_forge/dashboard/branches_presenter.rb app/views/chrono_forge/dashboard/workflows/_branches.html.erb test/presenters_test.rb
git commit -m "feat(dashboard): show live throughput and ETA for in-flight merges"
```

---

## Self-Review

**Spec coverage:** Issue 1 (early/repeat rekick) → Task 1 (pending-delta gate + touch debounce + metadata). Issue 2 (max-interval overshoot) → Task 2 (uncapped pending + ETA + exp backoff). Throughput on dashboard → Task 2 (persist `rate`/`eta_seconds`) + Task 4 (render). Doc → Task 3. Covered.

**Placeholder scan:** none — every code step has concrete code; Task 4 Steps 1 & 4 reference the dashboard's own factory helpers / duration helper (grep-and-match) rather than guessing at markup not yet read.

**Type consistency:** `reschedule_delay(pending, rate, motion, prev_delay, min_interval, max_interval)` — `rate` numeric (0 ⇒ no drain), `motion` ∈ `{:running, :dispatched, :none}`, `prev_delay` numeric/nil — matches every call site and unit test (all six pass a `motion` symbol). `perform` builds `motion` from `BranchProbe.running?`/`dispatched?` (both EXISTS). `rekick_dropped_jobs(branch_log_ids, pending_by_branch, prev_pending_by_branch)` returns `{branch_id => count}`. `record_poll!(…, next_poll_at:, interval:, rate_by_branch:, rekicked_by_branch:)` — final signature after Task 2; the Task-1 call sites are updated in Task 2 Step 4 (the sealed-wake call gains `interval: nil, rate_by_branch: {}`). Aggregate `prev_pending` is guarded on `logs.size == branch_log_ids.size && prior.all?` (#3). `superseded?(logs, token)` takes loaded logs. `ETA_FRACTION = 0.5` matches the `* 0.5` arithmetic. `CAP`/`FACTOR` removed and no longer referenced (grep to confirm). `BranchProbe.incomplete` used as `.count` (uncapped); `running?`/`dispatched?` added; `progressing` retained but unused by the poller. Dashboard `Merge` struct gains `:rate, :eta_seconds`, populated from `poll.dig("rate"/"eta_seconds")`.

**Verification requirement scan:** The prompt ("fix both issues", "update the doc") requests NO user verification, confirmation, or human sign-off. Answer: **NO.** No `requiresUserVerification` task needed.

---

## As shipped (post-review divergences)

The plan above is the pre-implementation design; three review rounds and a live
20k/100k/500k drive moved several things. What actually landed:

- **Rekick gate is the never-started (dispatched) count delta, not total pending
  (Task 1).** A `wait_until` child resuming drops total `pending` without any
  never-started child being consumed, so the pending-delta gate could defer
  recovery of a genuinely-dropped child behind staggered waits. The gate now keys
  off the `idle & started_at IS NULL` count falling since the prior poll (added
  `BranchProbe.dispatched`, persisted as `dispatched` in the poll metadata).
- **Cadence fallback is motion-aware (Task 2).** When no completion is observed:
  a `:running` child holds `min_interval` (anti-regression — a live child will
  finish), a `:dispatched`-but-unpicked straggler backs off exponentially, and a
  `:none` (blocked/waiting) branch backs off to `max_interval`. `motion` is
  computed lazily (only when `rate == 0`, off the hot drain path).
- **Dashboard throughput aggregates a multi-branch merge (Task 4).** The presenter
  sums per-branch `rate` and recomputes the combined ETA (not one branch's figure).
  `rate` is stored `round(3)` so a very slow but real drain still renders.
- **Poller queue is a first-class config.** `ChronoForge.configure { |c|
  c.branch_merge_queue = … }` (default `:default`) — the live drive showed the
  poller starves when it shares the fan-out's child queue, and that placement is
  our code's concern, not a user monkey-patch on `BranchMergeJob.queue_as`.
- **Auto-refresh is universal.** Marked on the dashboard layout's `<main>` so every
  page refreshes in place (was per-page opt-in; the detail page — where the
  throughput gauge lives — had been missed).
- **Screenshots** were refreshed from the live drives, and a "poller queue
  placement" trap was documented in `docs/fanout-scale-test.md`.

**Live validation (500k):** 500,000/500,000 children completed, parent converged,
11 poller passes (ETA cadence held throughout, not a single starved poll), and 200
children rekicked+recovered after a mid-drain worker restart — the rekick/debounce
path exercised at scale. Full engine suite green (263 tests); dashboard 106.
