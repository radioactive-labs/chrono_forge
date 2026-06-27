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
    assert_equal true, poll["sealed"]
    assert poll["last_polled_at"], "last_polled_at should be recorded"
    assert poll["next_poll_at"], "next_poll_at should be set while still polling"
    assert_equal 1, poll["polls"]
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
end
