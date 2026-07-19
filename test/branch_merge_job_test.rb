require "test_helper"

class BranchMergeJobTest < ActiveJob::TestCase
  def setup
    ChronoForge::Workflow.where(key: "bmj-parent").destroy_all
    @parent = ChronoForge::Workflow.create!(key: "bmj-parent", job_class: "SingleSpawnWorkflow")
    @log = @parent.execution_logs.create!(step_name: "branch$g", state: :completed)
  end

  def child!(state:, started_at: Time.current)
    ChronoForge::Workflow.create!(
      key: "c-#{SecureRandom.hex}", job_class: "NoopChild",
      parent_execution_log_id: @log.id, state: state, started_at: started_at
    )
  end

  def test_wakes_parent_when_all_complete
    child!(state: :completed)
    assert_enqueued_with(job: SingleSpawnWorkflow, args: ["bmj-parent"]) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  def test_reschedules_when_incomplete
    child!(state: :running)
    assert_enqueued_with(job: ChronoForge::BranchMergeJob) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
    assert_no_enqueued_jobs(only: SingleSpawnWorkflow)
  end

  def test_does_not_wake_when_branch_not_sealed
    unsealed = @parent.execution_logs.create!(step_name: "branch$h", state: :pending)
    # children all complete, but branch not sealed yet
    ChronoForge::Workflow.create!(key: "c-x", job_class: "NoopChild",
      parent_execution_log_id: unsealed.id, state: :completed, started_at: Time.current)
    assert_enqueued_with(job: ChronoForge::BranchMergeJob) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [unsealed.id], 5, 300)
    end
    assert_no_enqueued_jobs(only: SingleSpawnWorkflow)
  end

  def test_rekicks_never_started_child
    stuck = child!(state: :idle, started_at: nil)
    stuck.update_column(:updated_at, 10.minutes.ago)
    assert_enqueued_with(job: NoopChild, args: [stuck.key]) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  def test_does_not_rekick_running_child
    running = child!(state: :running, started_at: nil)
    running.update_column(:updated_at, 10.minutes.ago)
    assert_enqueued_with(job: ChronoForge::BranchMergeJob) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
    assert_no_enqueued_jobs(only: NoopChild)
  end

  # Fix 1: the poller retries TRANSIENT infrastructure errors so a DB blip does not
  # orphan the parent in :idle. Structural assertion (rescue_handlers) rather than
  # fighting test-adapter retry mechanics: the invariant is that the declaration is
  # in place so a real backend re-enqueues the job on a transient error.
  def test_poller_retries_on_transient_error
    assert ChronoForge::BranchMergeJob.rescue_handlers.any? { |klass, _| klass == "ActiveRecord::Deadlocked" },
      "BranchMergeJob must retry transient DB errors so they do not orphan the parent"
  end

  # The poller's queue is a first-class config (we own this job, not the user), read
  # per-enqueue so a change takes effect without redefining the class — this is the
  # supported way to keep the poller off a fan-out's saturated child queue.
  def test_branch_merge_queue_is_configurable
    ChronoForge.reset_configuration!
    assert_equal "default", ChronoForge::BranchMergeJob.new.queue_name
    ChronoForge.configure { |c| c.branch_merge_queue = :chrono_forge_pollers }
    assert_equal "chrono_forge_pollers", ChronoForge::BranchMergeJob.new.queue_name
  ensure
    ChronoForge.reset_configuration!
  end

  # A programming bug (e.g. the empty-input guard) must propagate loudly to the
  # backend's failed-job queue, NOT be silently retried-then-discarded.
  def test_empty_branch_log_ids_propagates_loudly
    assert_raises(ArgumentError) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [], 5, 300)
    end
  end

  # A freshly-dispatched idle child has NOT exceeded REKICK_AFTER yet, so it
  # must not be re-enqueued — only children stale past the threshold are
  # presumed dropped.
  def test_does_not_rekick_recent_idle_child
    recent = child!(state: :idle, started_at: nil)
    recent.update_column(:updated_at, 1.minute.ago)
    assert_no_enqueued_jobs(only: NoopChild) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  # Failed/stalled children need operator recovery — a blind rekick must never
  # touch them. Both are "incomplete" so pending > 0 and the poller does NOT
  # early-return; it must still skip them when selecting idle candidates.
  def test_does_not_rekick_failed_or_stalled_children
    failed = child!(state: :failed, started_at: nil)
    stalled = child!(state: :stalled, started_at: nil)
    failed.update_column(:updated_at, 10.minutes.ago)
    stalled.update_column(:updated_at, 10.minutes.ago)
    assert_no_enqueued_jobs(only: NoopChild) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  # A child that ran and is now parked on a wait/wait_until is :idle with
  # started_at SET — it has been picked up, just halted waiting. It must NOT be
  # mistaken for a dropped (never-run) child and rekicked: that would re-check the
  # wait condition prematurely and pile up duplicate scheduled jobs. The updated_at
  # here is deliberately stale (10 min) to prove started_at — not staleness — is
  # what spares it.
  def test_does_not_rekick_waiting_child
    waiting = child!(state: :idle, started_at: 20.minutes.ago)
    waiting.update_column(:updated_at, 10.minutes.ago)
    assert_no_enqueued_jobs(only: NoopChild) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  # When more stale-idle children exist than REKICK_BATCH, exactly REKICK_BATCH
  # are re-enqueued in one poll; the rest are handled on the next pass.
  def test_rekick_is_capped_at_batch_size
    stale = 10.minutes.ago
    rows = (ChronoForge::BranchMergeJob::REKICK_BATCH + 5).times.map do
      {
        key: "cap-#{SecureRandom.hex}",
        job_class: "NoopChild",
        parent_execution_log_id: @log.id,
        state: ChronoForge::Workflow.states[:idle],
        kwargs: {},
        options: {},
        context: {},
        created_at: stale,
        updated_at: stale
      }
    end
    ChronoForge::Workflow.insert_all(rows)

    assert_enqueued_jobs(ChronoForge::BranchMergeJob::REKICK_BATCH, only: NoopChild) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  # A rekicked child doesn't just get enqueued — it runs to :completed,
  # closing the full recovery loop.
  def test_rekicked_child_runs_to_completion
    stuck = child!(state: :idle, started_at: nil)
    stuck.update_column(:updated_at, 10.minutes.ago)

    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)

    perform_enqueued_jobs(only: NoopChild)

    assert stuck.reload.completed?, "rekicked child must run to completion"
  end

  # Each poll stamps its observable state onto the target branch log's metadata so
  # a dashboard can surface in-flight merges (ActiveJob can't be queried for the
  # scheduled poller). While work remains, next_poll_at is set.
  def test_records_poll_state_on_branch_log
    child!(state: :running)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)

    poll = @log.reload.metadata["poll"]
    assert poll, "poll state should be recorded on the branch log"
    assert_equal 1, poll["pending"]
    assert_equal 1, poll["spawned"], "total spawned (all children) counted and cached"
    assert_equal true, poll["sealed"]
    assert poll["last_polled_at"], "last_polled_at should be recorded"
    assert poll["next_poll_at"], "next_poll_at should be set while still polling"
    assert_equal 1, poll["polls"]
  end

  # The total spawned count is immutable once the branch is sealed, so the poller
  # counts it EXACTLY ONCE and caches it — a row appearing after the first poll must
  # not change the cached figure (proving it isn't recounted every pass).
  def test_caches_spawned_count_once_when_sealed
    child!(state: :running)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    assert_equal 1, @log.reload.metadata.dig("poll", "spawned")

    child!(state: :running) # a second child now exists
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    assert_equal 1, @log.reload.metadata.dig("poll", "spawned"),
      "spawned is cached once at seal, not recounted per poll"
  end

  # The poll state must not clobber spawn_each's cursors — both live in the same
  # branch-log metadata under separate keys.
  def test_poll_state_preserves_existing_branch_metadata
    @log.update!(metadata: {"cursors" => {"items" => {"pk" => 42}}})
    child!(state: :running)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)

    meta = @log.reload.metadata
    assert_equal 42, meta.dig("cursors", "items", "pk"), "spawn_each cursors must be preserved"
    assert meta["poll"], "poll state should be added alongside cursors"
  end

  # On the wake (done) poll, pending is 0 and there is no next poll scheduled.
  def test_records_final_poll_with_no_next_when_complete
    child!(state: :completed)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)

    poll = @log.reload.metadata["poll"]
    assert_equal 0, poll["pending"]
    assert_equal true, poll["sealed"]
    assert_nil poll["next_poll_at"], "no next poll once the merge is done"
  end

  # The poll counter accumulates across successive polls.
  def test_poll_count_increments_across_polls
    child!(state: :running)
    2.times do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
    assert_equal 2, @log.reload.metadata["poll"]["polls"]
  end

  # Fencing: a poller whose token no longer matches the branch log's stored token
  # has been superseded by a newer merge_branches pass. It must stop dead — no
  # reschedule, no parent wake, no rekick — even though there is pending work.
  def test_superseded_poller_with_stale_token_stops
    @log.update!(metadata: {"poll_token" => "current"})
    child!(state: :running) # would otherwise force a reschedule
    assert_no_enqueued_jobs do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300, "stale")
    end
  end

  # The current-token poller is the live chain and keeps polling.
  def test_current_token_poller_proceeds
    @log.update!(metadata: {"poll_token" => "tok"})
    child!(state: :running)
    assert_enqueued_with(job: ChronoForge::BranchMergeJob) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300, "tok")
    end
  end

  # A superseded poller must never clobber the newer chain's token or write poll
  # state — the stored token stays put and no "poll" key is written.
  def test_superseded_poller_does_not_touch_metadata
    @log.update!(metadata: {"poll_token" => "new"})
    child!(state: :running)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300, "old")
    meta = @log.reload.metadata
    assert_equal "new", meta["poll_token"], "stale poller must not rotate the token"
    assert_nil meta["poll"], "stale poller must not write poll state"
  end

  # Cadence: reschedule_delay(pending, rate, motion, prev_delay, min, max).
  # `rate` is children/s (0 unless the branch drained since the prior poll); `motion`
  # is :running | :never_started | :none. Positive rate => ETA-scaled delay (motion moot).
  def test_reschedule_delay_scales_with_measured_drain_rate
    job = ChronoForge::BranchMergeJob.new
    # rate 20/s, 800 left => ETA 40s; * 0.5 = 20s.
    assert_in_delta 20, job.send(:reschedule_delay, 800, 20.0, :running, nil, 5, 300), 0.001
  end

  def test_reschedule_delay_clamps_eta_to_max
    job = ChronoForge::BranchMergeJob.new
    assert_equal 300, job.send(:reschedule_delay, 100_000, 0.1, :running, nil, 5, 300)
  end

  def test_reschedule_delay_clamps_eta_to_min
    job = ChronoForge::BranchMergeJob.new
    assert_equal 5, job.send(:reschedule_delay, 1, 1000.0, :running, nil, 5, 300)
  end

  # A running child produced no completion this interval: HOLD the floor (it's
  # executing and will finish) — never back off, even with a large prior delay.
  # Anti-regression guard for slow / low-fan-out children.
  def test_reschedule_delay_running_holds_floor
    job = ChronoForge::BranchMergeJob.new
    assert_equal 5, job.send(:reschedule_delay, 1, 0.0, :running, nil, 5, 300)
    assert_equal 5, job.send(:reschedule_delay, 1, 0.0, :running, 200, 5, 300) # ignores prev_delay
  end

  # Only a dispatched-but-unpicked child left (rate 0, :never_started): back off
  # exponentially from the floor (no prior delay => start at min; then double).
  def test_reschedule_delay_backs_off_exponentially_for_dispatched_straggler
    job = ChronoForge::BranchMergeJob.new
    assert_equal 5, job.send(:reschedule_delay, 100, 0.0, :never_started, nil, 5, 300)
    assert_equal 10, job.send(:reschedule_delay, 100, 0.0, :never_started, 5, 5, 300)
    assert_equal 300, job.send(:reschedule_delay, 100, 0.0, :never_started, 200, 5, 300)
  end

  # Nothing can progress (all blocked/waiting) => straight to the max backstop.
  def test_reschedule_delay_uses_max_when_nothing_progresses
    job = ChronoForge::BranchMergeJob.new
    assert_equal 300, job.send(:reschedule_delay, 100, 0.0, :none, nil, 5, 300)
    assert_equal 300, job.send(:reschedule_delay, 100, 0.0, :none, 200, 5, 300)
  end

  # Delay actually applied this poll, read back from the recorded poll metadata.
  def poll_delay
    poll = @log.reload.metadata["poll"]
    Time.zone.parse(poll["next_poll_at"]) - Time.zone.parse(poll["last_polled_at"])
  end

  # The disaster case. A branch whose only incomplete children are blocked
  # (failed/stalled) can never complete without operator recovery. Polling at the
  # 5s floor forever would re-enqueue ~17k pollers/day per stuck branch. Instead it
  # backs off to max_interval — a cheap backstop that still notices a recovered
  # child within one interval.
  def test_blocked_only_branch_backs_off_to_max_interval
    child!(state: :failed)
    child!(state: :stalled)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    assert_in_delta 300, poll_delay, 2,
      "blocked-only branch must back off to max_interval, not spin at the 5s floor"
  end

  # A child parked on a wait/wait_until (idle, started_at SET) can't progress on
  # the poller's account either, so it must not pin the cadence at the floor.
  # (Currently lands at max_interval; a future enhancement may align it to the
  # wait's known resume deadline.)
  def test_waiting_only_branch_backs_off_from_floor
    child!(state: :idle, started_at: 20.minutes.ago)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    assert_operator poll_delay, :>, 5,
      "a waiting-only branch must not poll at the 5s floor"
  end

  # A genuinely progressing child (running, or dispatched-but-not-yet-started)
  # keeps the responsive floor so its completion is caught promptly.
  def test_progressing_child_keeps_responsive_floor
    child!(state: :running)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    assert_in_delta 5, poll_delay, 1
  end

  # Cadence is driven by the count of children that can progress, NOT the total
  # incomplete: blocked siblings must not slow polling of an active child.
  def test_blocked_siblings_do_not_slow_a_progressing_child
    child!(state: :running)
    5.times { child!(state: :failed) }
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    assert_in_delta 5, poll_delay, 1,
      "one progressing child polls fast regardless of blocked siblings"
  end

  # The backstop preserves recovery: a blocked child that is retried and completes
  # is noticed on the next poll and the parent is woken.
  def test_recovered_blocked_child_wakes_parent_on_next_poll
    failed = child!(state: :failed)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)

    failed.update!(state: :completed) # operator retry, eventually completes
    assert_enqueued_with(job: SingleSpawnWorkflow, args: ["bmj-parent"]) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  # Fix 1: the never-started (dispatched) count dropped since the prior poll =>
  # workers are consuming the branch's queue => a stale idle never-started child is
  # in line, not dropped. No rekick.
  def test_does_not_rekick_while_branch_is_draining
    @log.update!(metadata: {"poll" => {"never_started" => 5, "last_polled_at" => 30.seconds.ago.iso8601, "polls" => 1}})
    stale = child!(state: :idle, started_at: nil) # dispatched now = 1 < prior 5 => draining
    stale.update_column(:updated_at, 10.minutes.ago)
    assert_no_enqueued_jobs(only: NoopChild) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  # Never-started count unchanged since the prior poll (queue not being consumed)
  # => a genuinely dropped, stale never-started child IS rekicked.
  def test_rekicks_when_branch_has_gone_quiet
    @log.update!(metadata: {"poll" => {"never_started" => 1, "last_polled_at" => 30.seconds.ago.iso8601, "polls" => 1}})
    stale = child!(state: :idle, started_at: nil) # dispatched now = 1 == prior 1 => not draining
    stale.update_column(:updated_at, 10.minutes.ago)
    assert_enqueued_with(job: NoopChild, args: [stale.key]) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  # Fix 1 (the point of gating on never-started, not total pending): a wait/
  # wait_until child resuming + completing drops total pending, but that must NOT
  # mask a genuinely-dropped never-started child behind it. The dropped child is
  # still rekicked because the never-started count did not fall.
  def test_rekicks_dropped_child_when_only_waits_drain_pending
    @log.update!(metadata: {"poll" => {"pending" => 3, "never_started" => 1,
                                       "last_polled_at" => 30.seconds.ago.iso8601, "polls" => 2}})
    child!(state: :completed)                        # a wait that resumed + completed
    child!(state: :idle, started_at: 20.minutes.ago) # a child still parked on a wait
    dropped = child!(state: :idle, started_at: nil)  # genuinely dropped, never started
    dropped.update_column(:updated_at, 10.minutes.ago)
    # pending now = 2 (< prior 3 — the OLD pending gate would wrongly suppress) but
    # dispatched = 1 (== prior 1: no never-started child was consumed) => rekick.
    assert_enqueued_with(job: NoopChild, args: [dropped.key]) do
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

  # rekick_total is a running counter, not a per-poll value: it accumulates across
  # successive rekicking polls. The first poll rekicks child A (debouncing it); a
  # fresh stale child B on the second poll keeps the never-started count from
  # dropping (so the drain gate stays open) and is rekicked, carrying total 1 -> 2.
  def test_rekick_total_accumulates_across_polls
    a = child!(state: :idle, started_at: nil)
    a.update_column(:updated_at, 10.minutes.ago)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    assert_equal 1, @log.reload.metadata["poll"]["rekick_total"]

    # A is now debounced (touched fresh). Add a second stale child so the never-
    # started count rises to 2 (>= prior 1, gate open) and B gets rekicked.
    b = child!(state: :idle, started_at: nil)
    b.update_column(:updated_at, 10.minutes.ago)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    assert_equal 2, @log.reload.metadata["poll"]["rekick_total"]
  end

  # last_rekick_at is carried forward on a later poll that rekicks nothing (it is
  # only overwritten when a rekick actually fires), so the dashboard keeps the true
  # timestamp of the last recovery rather than nil'ing it on the next quiet poll.
  def test_last_rekick_at_preserved_on_zero_rekick_poll
    stale = child!(state: :idle, started_at: nil)
    stale.update_column(:updated_at, 10.minutes.ago)
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    first = @log.reload.metadata["poll"]["last_rekick_at"]
    assert first, "last_rekick_at should be set after the first rekick"

    # Second poll: the child was touched on rekick => no longer stale => no rekick.
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    poll = @log.reload.metadata["poll"]
    assert_equal 0, poll["rekicked"], "no rekick should fire on the second poll"
    assert_equal first, poll["last_rekick_at"], "last_rekick_at must be carried forward, not nil'd"
  end

  # Second poll: cadence driven by the drain rate measured from the first poll's
  # persisted pending, not backlog size — and that rate is persisted as throughput.
  # Seed 50 pending 60s ago, leave 40 incomplete => 10 drained over ~60s ≈ 0.167/s
  # => ETA 240s => * 0.5 => ~120s.
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
  # interval must keep the floor, NOT decay to the prior poll's backoff.
  def test_running_child_holds_floor_end_to_end
    @log.update!(metadata: {"poll" => {
      "pending" => 1, "interval" => 40, "last_polled_at" => 30.seconds.ago.iso8601, "polls" => 3
    }})
    child!(state: :running) # pending stays 1 => no drain => rate 0, motion :running
    ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    assert_in_delta 5, poll_delay, 1,
      "a running child must hold the floor, not decay to the 40s->80s backoff"
  end
end
