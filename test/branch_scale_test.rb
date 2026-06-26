require "test_helper"

class BranchScaleTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    User.delete_all
    25.times { |i| User.create!(name: "u#{i}", email: "u#{i}@e.com") }
  end

  def test_dispatch_uses_bulk_inserts_not_one_per_child
    inserts = 0
    pattern = /INSERT INTO ["`]?chrono_forge_workflows/i
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*a|
      inserts += 1 if pattern.match?(a.last[:sql].to_s)
    end
    # of: 10 over 25 users => ceil(25/10) = 3 insert_all statements for children.
    SpawnEachWorkflow.perform_later("scale-1", of: 10)
    perform_all_jobs
    ActiveSupport::Notifications.unsubscribe(sub)

    branch_log = ChronoForge::Workflow.find_by(key: "scale-1").execution_logs.find_by(step_name: "branch$grp")
    children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id)
    assert_equal 25, children.count, "all 25 children dispatched"

    # Expected inserts: 1 (parent row) + 3 (child batches via insert_all) = 4.
    # Child runs do NOT insert new rows (setup_workflow! finds the pre-inserted row
    # via find_by). Bound at 8 to allow minor framework overhead while being
    # meaningfully below 25 (which would indicate non-bulk per-child inserts).
    assert_operator inserts, :<=, 8,
      "expected bulk child inserts (~ceil(25/10)=3 plus parent row = ~4 total), got #{inserts}"
  end
end
