require "test_helper"

# Replay robustness + DB-impact tests for ChronoForge branch workflows.
#
# The executor replays the whole `perform` body on every resume. The key
# correctness properties proved here:
#
#  1. A replay pass does NOT re-create or re-enqueue any children (idempotent
#     dispatch — the sealed branch$<name> log guards the block).
#  2. Replay SELECT cost on chrono_forge_workflows is O(1) w.r.t. child count —
#     branches use an exists?-based probe, never a per-child scan.
#  3. Repeated replays converge: no duplicate children, parent re-completes
#     cleanly every time.
#  4. No writes (INSERTs/UPDATEs) to chrono_forge_workflows scale with child
#     count on replay — only the parent's own state transitions happen.
class BranchReplayTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
    User.delete_all
  end

  # ---------------------------------------------------------------------------
  # Test 1: A replay pass does not re-dispatch any children
  # ---------------------------------------------------------------------------
  def test_replay_does_not_redispatch_children
    5.times { |i| User.create!(name: "u#{i}", email: "u#{i}@example.com") }

    ReplayBranchWorkflow.perform_later("replay-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "replay-1")
    assert parent.completed?, "parent should be completed after initial run"

    branch_log = parent.execution_logs.find_by(step_name: "branch$items")
    children_before = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id)
    assert_equal 5, children_before.count, "should have 5 children after initial run"
    assert children_before.all?(&:completed?), "all children should be completed"

    child_keys_before = children_before.pluck(:key).to_set

    inserts_during_replay = count_sql("INSERT", "chrono_forge_workflows") do
      assert_no_enqueued_jobs(only: NoopChild) do
        replay_pass!("replay-1")
      end
    end

    assert_equal 0, inserts_during_replay,
      "replay must not INSERT any new rows into chrono_forge_workflows (no new children), got #{inserts_during_replay}"

    # Child count unchanged
    children_after = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.reload.id)
    assert_equal 5, children_after.count, "child count must not change on replay"

    # Same keys
    child_keys_after = children_after.pluck(:key).to_set
    assert_equal child_keys_before, child_keys_after, "child keys must be identical after replay"

    # All children still completed
    assert children_after.all?(&:completed?), "all children must remain completed after replay"

    # Parent completed again
    assert ChronoForge::Workflow.find_by(key: "replay-1").completed?,
      "parent must be completed after replay"
  end

  # ---------------------------------------------------------------------------
  # Test 2: Replay SELECT cost on the workflows table is independent of child
  # count — proves no per-child scan during the merge probe path.
  # ---------------------------------------------------------------------------
  def test_replay_select_cost_independent_of_child_count
    # Run with 3 children
    3.times { |i| User.create!(name: "few_#{i}", email: "few#{i}@example.com") }
    ReplayBranchWorkflow.perform_later("replay-few")
    perform_all_jobs
    assert ChronoForge::Workflow.find_by(key: "replay-few").completed?, "few-child workflow must complete"

    few = count_sql("SELECT", "chrono_forge_workflows") do
      replay_pass!("replay-few", drop_merge_logs: true)
    end

    # Reset and run with 30 children
    User.delete_all
    ChronoForge::Workflow.where.not(key: "replay-few").destroy_all
    30.times { |i| User.create!(name: "many_#{i}", email: "many#{i}@example.com") }
    ReplayBranchWorkflow.perform_later("replay-many")
    perform_all_jobs
    assert ChronoForge::Workflow.find_by(key: "replay-many").completed?, "many-child workflow must complete"

    many = count_sql("SELECT", "chrono_forge_workflows") do
      replay_pass!("replay-many", drop_merge_logs: true)
    end

    puts "replay SELECTs on workflows: few=#{few} many=#{many}"

    assert_equal few, many,
      "replay SELECT cost on chrono_forge_workflows must be constant regardless of child count " \
      "(got few=#{few} vs many=#{many}); a difference would indicate a per-child scan — a real replay bug"
  end

  # ---------------------------------------------------------------------------
  # Test 3: Repeated replays stay idempotent
  # ---------------------------------------------------------------------------
  def test_repeated_replays_stay_idempotent
    4.times { |i| User.create!(name: "loop_#{i}", email: "loop#{i}@example.com") }

    ReplayBranchWorkflow.perform_later("replay-loop")
    perform_all_jobs

    assert ChronoForge::Workflow.find_by(key: "replay-loop").completed?,
      "parent should be completed after initial run"

    3.times do |pass|
      assert_no_enqueued_jobs(only: NoopChild) do
        replay_pass!("replay-loop")
      end

      parent = ChronoForge::Workflow.find_by(key: "replay-loop")
      assert parent.completed?, "parent must be completed after replay pass #{pass + 1}"
      assert_equal true, parent.context["finalized"],
        "context[finalized] must be true after replay pass #{pass + 1}"

      branch_log = parent.execution_logs.find_by(step_name: "branch$items")
      children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id)
      assert_equal 4, children.count,
        "child count must remain 4 after replay pass #{pass + 1}"
      assert_equal 4, children.distinct.count(:key),
        "no duplicate child keys after replay pass #{pass + 1}"
      assert children.all?(&:completed?),
        "all children must remain completed after replay pass #{pass + 1}"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 4: Replay write impact is zero/bounded and does not scale with children
  # ---------------------------------------------------------------------------
  def test_replay_write_impact_is_zero_on_workflows_table
    # Measure INSERTs and UPDATEs for 5 children to assert baseline
    5.times { |i| User.create!(name: "write_#{i}", email: "write#{i}@example.com") }
    ReplayBranchWorkflow.perform_later("replay-writes")
    perform_all_jobs

    inserts = count_sql("INSERT", "chrono_forge_workflows") { replay_pass!("replay-writes") }
    updates_5 = count_sql("UPDATE", "chrono_forge_workflows") { replay_pass!("replay-writes") }

    assert_equal 0, inserts, "replay must not INSERT any workflow rows (got #{inserts})"
    puts "replay UPDATEs on workflows (5 children): #{updates_5}"

    # Now measure UPDATEs with 30 children and assert the count does NOT scale
    User.delete_all
    ChronoForge::Workflow.where.not(key: "replay-writes").destroy_all
    30.times { |i| User.create!(name: "write30_#{i}", email: "write30_#{i}@example.com") }
    ReplayBranchWorkflow.perform_later("replay-writes-30")
    perform_all_jobs

    inserts_30 = count_sql("INSERT", "chrono_forge_workflows") { replay_pass!("replay-writes-30") }
    updates_30 = count_sql("UPDATE", "chrono_forge_workflows") { replay_pass!("replay-writes-30") }

    assert_equal 0, inserts_30, "replay must not INSERT any workflow rows for 30 children (got #{inserts_30})"
    puts "replay UPDATEs on workflows (30 children): #{updates_30}"

    assert_equal updates_5, updates_30,
      "replay UPDATE count must not scale with child count " \
      "(got #{updates_5} for 5 children vs #{updates_30} for 30 children); " \
      "children must never be updated during a parent replay pass"
  end

  private

  # Count SQL statements matching op (INSERT|SELECT|UPDATE|DELETE) against a table.
  def count_sql(op, table)
    pattern = /#{op}\b.*\b#{Regexp.escape(table)}\b/i
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*a|
      sql = a.last[:sql].to_s
      count += 1 if pattern.match?(sql) && !sql.start_with?("PRAGMA", "BEGIN", "COMMIT")
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  # Simulate a replay pass of an already-finished workflow: reset it to idle and
  # drop the terminal completion log (and optionally the merge logs, to force the
  # merge to re-probe instead of short-circuiting on its completed log), then
  # re-run perform. The branch$ logs stay SEALED, so the branch blocks skip.
  def replay_pass!(key, drop_merge_logs: false)
    wf = ChronoForge::Workflow.find_by(key: key)
    wf.execution_logs.where(step_name: "$workflow_completion$").delete_all
    wf.execution_logs.where("step_name LIKE 'merge$%'").delete_all if drop_merge_logs
    wf.update_columns(state: ChronoForge::Workflow.states[:idle], locked_at: nil, locked_by: nil)
    ReplayBranchWorkflow.perform_later(key)
    perform_all_jobs
  end
end
