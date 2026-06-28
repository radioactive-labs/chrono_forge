require "test_helper"

class LockStrategyTest < ActiveJob::TestCase
  LockStrategy = ChronoForge::Executor::LockStrategy

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def make_workflow(locked_by:)
    ChronoForge::Workflow.create!(
      key: "lock_test_#{SecureRandom.hex(4)}",
      job_class: "KitchenSink",
      kwargs: {},
      options: {},
      context: {"big" => "x" * 1000},
      state: :running,
      locked_by: locked_by,
      locked_at: Time.current
    )
  end

  def make_idle_workflow(started_at:)
    ChronoForge::Workflow.create!(
      key: "lock_test_#{SecureRandom.hex(4)}",
      job_class: "KitchenSink",
      kwargs: {},
      options: {},
      context: {},
      state: :idle,
      started_at: started_at
    )
  end

  def test_acquire_lock_stamps_started_at_when_unset
    # Branch children are pre-inserted by their parent without started_at; the
    # first execution must stamp it. Folding that stamp into the lock-acquire
    # transaction saves a standalone UPDATE (one fsync) per child on fan-outs.
    workflow = make_idle_workflow(started_at: nil)

    LockStrategy.acquire_lock("job-a", workflow, max_duration: 10.minutes)

    workflow.reload
    assert workflow.started_at, "acquire_lock should stamp started_at when it was nil"
    assert_equal "job-a", workflow.locked_by
  end

  def test_acquire_lock_preserves_existing_started_at
    original = 1.hour.ago.change(usec: 0)
    workflow = make_idle_workflow(started_at: original)

    LockStrategy.acquire_lock("job-a", workflow, max_duration: 10.minutes)

    workflow.reload
    assert_in_delta original, workflow.started_at, 1.second,
      "acquire_lock must not overwrite an already-set started_at"
  end

  def test_acquire_lock_stamps_started_at_within_the_lock_update
    # The stamp should ride along the existing lock UPDATE, not be its own write.
    workflow = make_idle_workflow(started_at: nil)

    updates = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      sql = args.last[:sql].to_s
      updates << sql if sql.match?(/UPDATE ["`]?chrono_forge_workflows/i)
    end
    begin
      LockStrategy.acquire_lock("job-a", workflow, max_duration: 10.minutes)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 1, updates.size,
      "lock acquire (with started_at stamp) should be a single workflows UPDATE, got #{updates.size}"
    assert_match(/started_at/i, updates.first, "the lock UPDATE should also set started_at")
    assert_match(/locked_by/i, updates.first, "the lock UPDATE should set the lock owner")
  end

  def test_acquire_lock_raises_concurrent_execution_error_when_freshly_locked
    workflow = make_workflow(locked_by: "job-b")

    # job-a tries to acquire a lock held by job-b whose lock is still fresh.
    # This must surface as a clean ConcurrentExecutionError, not a NameError
    # raised while building the message string.
    error = assert_raises(ChronoForge::Executor::ConcurrentExecutionError) do
      LockStrategy.acquire_lock("job-a", workflow, max_duration: 10.minutes)
    end

    assert_includes error.message, workflow.key
    assert_includes error.message, "job-a"
    assert_includes error.message, "job-b"
    # The message should name the strategy class, not the literal "Class" that
    # `self.class` produced inside the `class << self` singleton.
    assert_includes error.message, "LockStrategy"
    refute_match(/ChronoForge:Class\b/, error.message)
  end

  def test_release_lock_clears_lock_for_owning_job
    workflow = make_workflow(locked_by: "job-a")

    LockStrategy.release_lock("job-a", workflow)

    workflow.reload
    assert_nil workflow.locked_by, "lock owner should be cleared"
    assert_nil workflow.locked_at, "lock timestamp should be cleared"
    assert workflow.idle?, "a running workflow should return to idle on release"
  end

  def test_release_lock_detects_takeover_by_another_job
    workflow = make_workflow(locked_by: "job-b")

    # job-a thinks it holds the lock but job-b has taken over (its id is in the DB).
    assert_raises(ChronoForge::Executor::LongRunningConcurrentExecutionError) do
      LockStrategy.release_lock("job-a", workflow)
    end
  end

  def test_force_release_ignores_ownership
    workflow = make_workflow(locked_by: "job-b")

    LockStrategy.release_lock("job-a", workflow, force: true)

    workflow.reload
    assert_nil workflow.locked_by
    assert workflow.idle?
  end

  def test_release_lock_does_not_load_heavy_columns
    workflow = make_workflow(locked_by: "job-a")

    selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      sql = args.last[:sql].to_s
      selects << sql if sql.match?(/SELECT.+chrono_forge_workflows/i)
    end
    begin
      LockStrategy.release_lock("job-a", workflow)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    refute selects.empty?, "release should still read the lock owner from the DB"

    # A full-row reload emits `SELECT "chrono_forge_workflows".*`, dragging the
    # heavy JSON columns (context/kwargs/options) into memory. A targeted
    # projection names just the columns it needs.
    selects.each do |sql|
      refute_match(/chrono_forge_workflows"?\.\*/i, sql,
        "release_lock should not SELECT * (full row incl. heavy JSON): #{sql}")
    end
    assert selects.any? { |sql| sql.match?(/locked_by/i) },
      "release_lock should project the lock columns explicitly, got: #{selects.inspect}"
  end
end
