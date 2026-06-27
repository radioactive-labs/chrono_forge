require "test_helper"

class BranchRecoveryTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    User.delete_all
    @users = 25.times.map { |i| User.create!(name: "u#{i}", email: "u#{i}@e.com") }
  end

  # Prove cursor-resume + boundary-dedup with a real ChaoticJob glitch.
  #
  # The glitch fires once "before" advance_cursor! in the AR path — i.e. after
  # dispatch_children commits the first batch (insert_all + perform_all_later) but
  # before the cursor is persisted. ChaoticJob retries the parent job, which must
  # RESUME spawn_each from start: nil (the cursor never advanced), re-yielding the
  # whole stream. Because AR children are keyed by record.id ("key$grp$items_<id>"),
  # the re-yielded boundary records collapse to identical keys — insert_all dedups
  # them. And the queue-idempotency fix means already-run children are NOT
  # re-enqueued, so none end up failed/stalled.
  def test_resumes_dispatch_from_cursor_with_no_duplicate_children
    branch_rb = ChronoForge::Executor::Methods::Branch
      .instance_method(:spawn_each).source_location[0]

    # 1-based line of the AR-path advance_cursor! call (inside find_in_batches).
    advance_line = File.readlines(branch_rb)
      .each_with_index
      .find { |line, _| line.include?("advance_cursor!") && line.include?("pk:") }
      .then { |_line, idx| idx + 1 }

    run_scenario(
      SpawnEachWorkflow.new("rec-1", of: 10),
      glitch: ["before", "#{branch_rb}:#{advance_line}"]
    )

    parent = ChronoForge::Workflow.find_by(key: "rec-1")
    assert parent.completed?, "workflow should complete after cursor-resume"

    branch_log = parent.execution_logs.find_by(step_name: "branch$grp")
    children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id)

    assert_equal 25, children.count, "exactly N children after cursor-resume (no extras)"
    assert_equal 25, children.distinct.count(:key), "no duplicate child keys"

    # The queue-idempotency guarantee: a child dispatched before the glitch must
    # not be re-enqueued+re-run on resume. A spurious re-run of a completed child
    # raises NotExecutableError → stalled/failed. Zero such children proves the fix.
    bad = children.where(state: [
      ChronoForge::Workflow.states[:failed],
      ChronoForge::Workflow.states[:stalled]
    ]).count
    assert_equal 0, bad, "no child should be failed/stalled from a spurious re-run"
  end

  # AR path, mid-stream: glitch fires AFTER the first batch's advance_cursor! so the
  # cursor is persisted with start: <users[of-1].id>. On resume, spawn_each picks up
  # from that non-nil PK — it does NOT restart from scratch. The boundary record is
  # re-yielded (inclusive keyset) but insert_all dedups its identical key, so we
  # still end up with exactly 25 distinct children and zero failed/stalled.
  def test_ar_path_resumes_mid_stream_from_nonnil_cursor
    branch_rb = ChronoForge::Executor::Methods::Branch
      .instance_method(:spawn_each).source_location[0]

    ar_cursor_line = File.readlines(branch_rb)
      .each_with_index
      .find { |line, _| line.include?("advance_cursor!") && line.include?("pk:") }
      .then { |_line, idx| idx + 1 }

    run_scenario(
      SpawnEachWorkflow.new("ar-mid", of: 10),
      glitch: ["after", "#{branch_rb}:#{ar_cursor_line}"]
    )

    parent = ChronoForge::Workflow.find_by(key: "ar-mid")
    assert parent.completed?, "workflow should complete after mid-stream AR cursor resume"

    branch_log = parent.execution_logs.find_by(step_name: "branch$grp")
    children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id)

    assert_equal 25, children.count, "exactly 25 children after mid-stream AR resume (no extras)"
    assert_equal 25, children.distinct.count(:key), "no duplicate child keys"

    bad = children.where(state: [
      ChronoForge::Workflow.states[:failed],
      ChronoForge::Workflow.states[:stalled]
    ]).count
    assert_equal 0, bad, "no child should be failed/stalled after mid-stream AR resume"
  end

  # Enumerable path, mid-stream: glitch fires AFTER the first batch's advance_cursor!
  # (n: n line). The cursor is persisted at n=of, so resume calls source.drop(n) and
  # skips the already-dispatched items — no overlap, no gap, no dupes.
  def test_enumerable_path_resumes_mid_stream
    branch_rb = ChronoForge::Executor::Methods::Branch
      .instance_method(:spawn_each).source_location[0]

    enum_cursor_line = File.readlines(branch_rb)
      .each_with_index
      .find { |line, _| line.include?("advance_cursor!") && line.include?("n: n") }
      .then { |_line, idx| idx + 1 }

    items = (1..25).to_a
    run_scenario(
      EnumSpawnWorkflow.new("enum-mid", items: items, of: 10),
      glitch: ["after", "#{branch_rb}:#{enum_cursor_line}"]
    )

    parent = ChronoForge::Workflow.find_by(key: "enum-mid")
    assert parent.completed?, "workflow should complete after mid-stream enumerable resume"

    branch_log = parent.execution_logs.find_by(step_name: "branch$grp")
    children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id)

    assert_equal 25, children.count, "exactly 25 children after mid-stream enum resume (no extras)"
    assert_equal 25, children.distinct.count(:key), "no duplicate child keys"

    bad = children.where(state: [
      ChronoForge::Workflow.states[:failed],
      ChronoForge::Workflow.states[:stalled]
    ]).count
    assert_equal 0, bad, "no child should be failed/stalled after mid-stream enum resume"
  end

  # Enumerable path, from-scratch: glitch fires BEFORE the first advance_cursor! in
  # the enum branch — n is never persisted. On resume drop(0) re-yields the whole
  # stream, producing identical things_{n} keys; insert_all dedups them so no
  # duplicates exist and all 25 children complete cleanly.
  def test_enumerable_path_resumes_from_scratch_dedups
    branch_rb = ChronoForge::Executor::Methods::Branch
      .instance_method(:spawn_each).source_location[0]

    enum_cursor_line = File.readlines(branch_rb)
      .each_with_index
      .find { |line, _| line.include?("advance_cursor!") && line.include?("n: n") }
      .then { |_line, idx| idx + 1 }

    items = (1..25).to_a
    run_scenario(
      EnumSpawnWorkflow.new("enum-scratch", items: items, of: 10),
      glitch: ["before", "#{branch_rb}:#{enum_cursor_line}"]
    )

    parent = ChronoForge::Workflow.find_by(key: "enum-scratch")
    assert parent.completed?, "workflow should complete after from-scratch enum resume"

    branch_log = parent.execution_logs.find_by(step_name: "branch$grp")
    children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id)

    assert_equal 25, children.count, "exactly 25 children after from-scratch enum resume (no dupes)"
    assert_equal 25, children.distinct.count(:key), "no duplicate child keys"

    bad = children.where(state: [
      ChronoForge::Workflow.states[:failed],
      ChronoForge::Workflow.states[:stalled]
    ]).count
    assert_equal 0, bad, "no child should be failed/stalled after from-scratch enum resume"
  end

  # Finest-grained gap: crash AFTER insert_all commits child rows (:idle) but BEFORE
  # perform_all_later enqueues them. On resume the branch re-dispatches: insert_all
  # ignores the existing idle rows; the idle-filter finds them still :idle and
  # enqueues them. Every child inserted-but-never-enqueued still runs to :completed.
  def test_resumes_when_crash_between_insert_and_enqueue
    branch_rb = ChronoForge::Executor::Methods::Branch
      .instance_method(:spawn_each).source_location[0]

    perform_all_later_line = File.readlines(branch_rb)
      .each_with_index
      .find { |line, _| line.include?("ActiveJob.perform_all_later") }
      .then { |_line, idx| idx + 1 }

    run_scenario(
      SpawnEachWorkflow.new("gap-1", of: 10),
      glitch: ["before", "#{branch_rb}:#{perform_all_later_line}"]
    )

    parent = ChronoForge::Workflow.find_by(key: "gap-1")
    assert parent.completed?, "workflow should complete after insert/enqueue gap resume"

    branch_log = parent.execution_logs.find_by(step_name: "branch$grp")
    children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id)

    assert_equal 25, children.count, "exactly 25 children after insert/enqueue gap resume"
    assert_equal 25, children.distinct.count(:key), "no duplicate child keys"

    bad = children.where(state: [
      ChronoForge::Workflow.states[:failed],
      ChronoForge::Workflow.states[:stalled]
    ]).count
    assert_equal 0, bad, "no child should be failed/stalled after insert/enqueue gap"

    # Key property: children inserted but never enqueued (still :idle at crash time)
    # must be picked up and run to :completed on resume — none should be stuck :idle.
    stuck_idle = children.where(state: ChronoForge::Workflow.states[:idle]).count
    assert_equal 0, stuck_idle, "no child should remain :idle — all must be run after insert/enqueue gap"
  end

  # Focused unit test of the dispatch filter: a child already :completed must NOT
  # be re-enqueued when its chunk is re-dispatched on resume. We pre-seed a
  # completed child whose key the re-yielded stream will produce, then re-run
  # spawn_each from a cursor that re-yields it (start at its PK). The completed
  # child's row stays completed and no fresh NoopChild job is enqueued for its key.
  def test_dispatch_does_not_reenqueue_completed_children
    # Build a partially-dispatched branch: parent idle, branch pending, and the
    # first user's child already COMPLETED (as if it ran before a crash).
    parent = ChronoForge::Workflow.create!(
      key: "rec-2", job_class: "SpawnEachWorkflow",
      kwargs: {"of" => 10}, options: {}, context: {}, state: :idle
    )
    branch_log = parent.execution_logs.create!(
      step_name: "branch$grp", state: :pending, started_at: Time.current, metadata: {}
    )

    first_user = @users.first
    completed_key = "rec-2$grp$items_#{first_user.id}"
    completed_child = ChronoForge::Workflow.create!(
      key: completed_key, job_class: "NoopChild",
      kwargs: {user_id: first_user.id}, options: {}, context: {},
      state: :completed, parent_execution_log_id: branch_log.id
    )

    # Re-run. spawn_each replays from start: nil, re-yielding first_user first.
    # dispatch_children's insert_all ignores the existing completed row, and the
    # idle-filter skips enqueuing it; only the genuinely-new (idle) children run.
    SpawnEachWorkflow.perform_later("rec-2", of: 10)
    perform_all_jobs

    # The completed child must not have been re-run (no NotExecutableError, state
    # unchanged) — and exactly one row exists for its key (no duplicate insert).
    completed_child.reload
    assert completed_child.completed?, "pre-completed child must stay completed (not re-run)"
    assert_equal 1, ChronoForge::Workflow.where(key: completed_key).count,
      "no duplicate row for the completed child's key"

    # The whole fan-out still finishes: 25 distinct children, parent completed.
    children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id)
    assert_equal 25, children.count, "all 25 children present after resume"
    assert_equal 25, children.distinct.count(:key), "no duplicate child keys"
    assert parent.reload.completed?, "workflow should complete"
    assert_equal 0, children.where(state: [
      ChronoForge::Workflow.states[:failed],
      ChronoForge::Workflow.states[:stalled]
    ]).count, "no failed/stalled children"
  end

  # setup_workflow! stamps started_at the first time a pre-inserted child runs.
  # Branch children are inserted by the parent (insert_all) without started_at;
  # this stamp is what lets the rekick poller tell "ran, now waiting" (started_at
  # set) from "never picked up / dropped" (started_at nil).
  def test_pre_inserted_child_records_started_at_on_first_run
    row = ChronoForge::Workflow.create!(
      key: "started-at-1", job_class: "NoopChild",
      kwargs: {}, options: {}, context: {}, state: :idle, started_at: nil
    )
    assert_nil row.started_at

    NoopChild.perform_later("started-at-1")
    perform_all_jobs

    row.reload
    assert row.completed?, "child should complete"
    assert_not_nil row.started_at, "started_at must be stamped on first execution"
  end
end
