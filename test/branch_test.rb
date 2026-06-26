require "test_helper"

class BranchTest < ActiveJob::TestCase
  include ChaoticJob::Helpers
  def test_spawn_creates_linked_child_and_seals_branch
    SingleSpawnWorkflow.perform_later("ss-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "ss-1")
    branch_log = parent.execution_logs.find_by(step_name: "branch$grp")
    assert branch_log.completed?, "branch should seal when the block closes"

    child = ChronoForge::Workflow.find_by(key: "ss-1$grp$child")
    assert child, "child should be created with deterministic key"
    assert_equal "NoopChild", child.job_class
    assert_equal branch_log.id, child.parent_execution_log_id
    assert_equal({"foo" => "bar"}, child.kwargs)
  end

  def test_spawn_outside_branch_raises
    workflow = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      def perform = spawn(:x, NoopChild)
    end
    Object.const_set(:BareSpawnWorkflow, workflow)
    BareSpawnWorkflow.perform_later("bare-1")
    assert_raises(ChronoForge::Executor::NotInBranchError) { perform_all_jobs }
  ensure
    Object.send(:remove_const, :BareSpawnWorkflow) if defined?(BareSpawnWorkflow)
  end

  def test_sealed_branch_block_is_not_re_executed_on_replay
    SingleSpawnWorkflow.perform_later("ss-2")
    perform_all_jobs
    wf = ChronoForge::Workflow.find_by(key: "ss-2")
    branch_log = wf.execution_logs.find_by(step_name: "branch$grp")

    # Simulate a mid-execution replay: reset the workflow back to idle so the
    # executor will accept it again, and remove the completion log so the
    # engine re-runs the perform body. The branch$grp log is already completed,
    # so the branch block must be skipped entirely (no new child INSERT).
    wf.execution_logs.find_by(step_name: "$workflow_completion$")&.destroy
    wf.update_columns(state: ChronoForge::Workflow.states[:idle])

    inserts = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*a|
      inserts += 1 if /INSERT INTO ["`]?chrono_forge_workflows/i.match?(a.last[:sql].to_s)
    end
    SingleSpawnWorkflow.perform_later("ss-2")
    perform_all_jobs
    ActiveSupport::Notifications.unsubscribe(sub)

    assert_equal 0, inserts, "sealed branch must not re-dispatch children on replay"
    assert_equal 1, ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id).count
  end
end
