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
end
