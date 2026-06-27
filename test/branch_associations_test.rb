require "test_helper"

class BranchAssociationsTest < ActiveJob::TestCase
  def test_parent_execution_log_and_spawned_workflows_round_trip
    parent = ChronoForge::Workflow.create!(key: "p-#{SecureRandom.hex}", job_class: "X")
    log = parent.execution_logs.create!(step_name: "branch$grp")
    child = ChronoForge::Workflow.create!(
      key: "c-#{SecureRandom.hex}", job_class: "Y", parent_execution_log_id: log.id
    )

    assert_equal log, child.parent_execution_log
    assert_includes log.spawned_workflows, child
  end
end
