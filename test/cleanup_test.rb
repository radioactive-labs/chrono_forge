require "test_helper"

class CleanupTest < ActiveJob::TestCase
  Cleanup = ChronoForge::Cleanup

  def setup
    ChronoForge::Workflow.destroy_all
  end

  # created_age = when the workflow started; terminal_age = when it became
  # terminal (updated_at). They differ for long-running workflows.
  def make_workflow(state:, created_age: 1.day, terminal_age: nil, key: nil)
    wf = ChronoForge::Workflow.create!(
      key: key || "cleanup_#{SecureRandom.hex(4)}",
      job_class: "KitchenSink",
      kwargs: {}, options: {}, context: {},
      state: state
    )
    wf.update_column(:created_at, created_age.ago)
    if terminal_age
      wf.update_column(:updated_at, terminal_age.ago)
      wf.update_column(:completed_at, terminal_age.ago) if state == :completed
    end
    wf
  end

  def add_logs(workflow)
    ChronoForge::ExecutionLog.create!(workflow: workflow, step_name: "durably_execute$step", state: :completed)
    ChronoForge::ErrorLog.create!(workflow: workflow, error_class: "X", error_message: "y")
  end

  def make_rep(workflow, task, scheduled:, state:, created_age: 0.days)
    log = ChronoForge::ExecutionLog.create!(
      workflow: workflow,
      step_name: "durably_repeat$#{task}$#{scheduled.to_i}",
      state: state,
      metadata: {"scheduled_for" => scheduled.iso8601}
    )
    log.update_column(:created_at, created_age.ago)
    log
  end

  def make_coordination(workflow, task, last_execution_at:)
    ChronoForge::ExecutionLog.create!(
      workflow: workflow,
      step_name: "durably_repeat$#{task}",
      state: :pending,
      metadata: {"last_execution_at" => last_execution_at&.iso8601}
    )
  end

  def exists?(log)
    ChronoForge::ExecutionLog.exists?(log.id)
  end

  # --- workflow deletion (retention measured from terminal transition) ----

  def test_deletes_old_terminal_workflows_and_cascades_logs
    old_done = make_workflow(state: :completed, terminal_age: 40.days)
    old_failed = make_workflow(state: :failed, terminal_age: 40.days)
    add_logs(old_done)
    add_logs(old_failed)

    result = Cleanup.run(older_than: 30.days)

    refute ChronoForge::Workflow.exists?(old_done.id)
    refute ChronoForge::Workflow.exists?(old_failed.id)
    assert_equal 0, ChronoForge::ExecutionLog.where(workflow_id: [old_done.id, old_failed.id]).count
    assert_equal 0, ChronoForge::ErrorLog.where(workflow_id: [old_done.id, old_failed.id]).count
    assert_equal 2, result[:workflows]
  end

  def test_keeps_recent_terminal_workflows
    recent = make_workflow(state: :completed, terminal_age: 5.days)
    Cleanup.run(older_than: 30.days)
    assert ChronoForge::Workflow.exists?(recent.id)
  end

  def test_keeps_long_running_workflow_that_only_just_completed
    # Started a year ago, finished yesterday. Retention must be measured from
    # completion, not creation, so it must be kept.
    wf = make_workflow(state: :completed, created_age: 365.days, terminal_age: 1.day)
    Cleanup.run(older_than: 30.days)
    assert ChronoForge::Workflow.exists?(wf.id),
      "a long-running workflow that just completed must not be deleted on creation age"
  end

  def test_keeps_long_running_workflow_that_only_just_failed
    wf = make_workflow(state: :failed, created_age: 365.days, terminal_age: 1.day)
    Cleanup.run(older_than: 30.days)
    assert ChronoForge::Workflow.exists?(wf.id),
      "a long-running workflow that just failed must not be deleted on creation age"
  end

  def test_keeps_old_non_terminal_workflows
    running = make_workflow(state: :running, created_age: 90.days)
    idle = make_workflow(state: :idle, created_age: 90.days)
    stalled = make_workflow(state: :stalled, created_age: 90.days)

    Cleanup.run(older_than: 30.days)

    assert ChronoForge::Workflow.exists?(running.id), "running workflow must never be cleaned"
    assert ChronoForge::Workflow.exists?(idle.id), "idle workflow must never be cleaned"
    assert ChronoForge::Workflow.exists?(stalled.id), "stalled workflow must not be cleaned by default"
  end

  def test_completed_and_failed_retention_can_differ
    old_completed = make_workflow(state: :completed, terminal_age: 20.days)
    old_failed = make_workflow(state: :failed, terminal_age: 20.days)

    Cleanup.run(older_than: 365.days, completed_older_than: 10.days)

    refute ChronoForge::Workflow.exists?(old_completed.id), "completed should use completed_older_than (10d)"
    assert ChronoForge::Workflow.exists?(old_failed.id), "failed should fall back to older_than (365d)"
  end

  def test_failed_older_than_overrides_independently
    old_failed = make_workflow(state: :failed, terminal_age: 20.days)
    old_completed = make_workflow(state: :completed, terminal_age: 20.days)

    Cleanup.run(older_than: 365.days, failed_older_than: 10.days)

    refute ChronoForge::Workflow.exists?(old_failed.id), "failed should use failed_older_than (10d)"
    assert ChronoForge::Workflow.exists?(old_completed.id), "completed should fall back to older_than (365d)"
  end

  # --- repetition-log pruning (frontier + scheduled-time window) ----------

  def test_repetition_pruning_off_by_default
    workflow = make_workflow(state: :running)
    make_coordination(workflow, "task", last_execution_at: 1.year.ago)
    old_rep = make_rep(workflow, "task", scheduled: 2.years.ago, state: :completed)

    Cleanup.run(older_than: 30.days)

    assert exists?(old_rep), "repetition pruning must require an explicit opt-in window"
  end

  def test_prunes_only_repetition_logs_strictly_behind_the_frontier
    workflow = make_workflow(state: :running)
    frontier_time = 30.days.ago
    coord = make_coordination(workflow, "task", last_execution_at: frontier_time)

    behind = make_rep(workflow, "task", scheduled: 31.days.ago, state: :completed)
    at_frontier = make_rep(workflow, "task", scheduled: frontier_time, state: :completed)
    ahead = make_rep(workflow, "task", scheduled: 29.days.ago, state: :completed)
    pending = make_rep(workflow, "task", scheduled: 32.days.ago, state: :pending)

    result = Cleanup.run(older_than: 365.days, prune_repetition_logs_older_than: 7.days)

    refute exists?(behind), "completed repetition strictly behind the frontier should be pruned"
    assert exists?(at_frontier), "repetition at the frontier must be kept (next = frontier + every)"
    assert exists?(ahead), "repetition ahead of the frontier (catch-up anchor) must be kept"
    assert exists?(pending), "pending repetition must always be kept"
    assert exists?(coord), "coordination log must always be kept"
    assert_equal 1, result[:repetition_logs]
  end

  def test_does_not_prune_when_coordination_has_no_frontier_yet
    workflow = make_workflow(state: :running)
    make_coordination(workflow, "task", last_execution_at: nil)
    rep = make_rep(workflow, "task", scheduled: 1.year.ago, state: :completed)

    Cleanup.run(older_than: 365.days, prune_repetition_logs_older_than: 7.days)

    assert exists?(rep), "with no established frontier, nothing can be safely pruned"
  end

  def test_prunes_catch_up_repetition_by_scheduled_time_not_created_at
    # A catch-up repetition: scheduled a year ago (behind the frontier) but its
    # row was only created today during fast-forward. It must be pruned based on
    # its scheduled time, not its recent created_at.
    workflow = make_workflow(state: :running)
    make_coordination(workflow, "task", last_execution_at: 1.day.ago)
    rep = make_rep(workflow, "task", scheduled: 1.year.ago, state: :completed, created_age: 0.days)

    result = Cleanup.run(older_than: 365.days, prune_repetition_logs_older_than: 30.days)

    refute exists?(rep), "a catch-up repetition scheduled long ago must be pruned despite a recent created_at"
    assert_equal 1, result[:repetition_logs]
  end

  def test_prunes_correctly_across_multiple_batches
    workflow = make_workflow(state: :running)
    make_coordination(workflow, "task", last_execution_at: 1.day.ago)

    # More behind-frontier completed repetitions than the batch size, so pruning
    # must span several batches without skipping or double-deleting any.
    behind = (1..7).map { |i| make_rep(workflow, "task", scheduled: (10 + i).days.ago, state: :completed) }
    kept_pending = make_rep(workflow, "task", scheduled: 50.days.ago, state: :pending)

    result = Cleanup.run(older_than: 365.days, prune_repetition_logs_older_than: 1.day, batch_size: 2)

    assert_equal 7, result[:repetition_logs], "all behind-frontier completed repetitions should be pruned"
    behind.each { |log| refute exists?(log), "every behind-frontier repetition should be gone" }
    assert exists?(kept_pending), "pending repetition must be kept"
  end

  def test_keeps_recently_scheduled_repetition_even_if_row_is_old
    # Scheduled within the window (so kept), even though its row was created
    # long ago and it sits behind the frontier.
    workflow = make_workflow(state: :running)
    make_coordination(workflow, "task", last_execution_at: 1.day.ago)
    rep = make_rep(workflow, "task", scheduled: 2.days.ago, state: :completed, created_age: 60.days)

    Cleanup.run(older_than: 365.days, prune_repetition_logs_older_than: 30.days)

    assert exists?(rep), "repetition scheduled within the window must be kept regardless of its created_at"
  end
end
