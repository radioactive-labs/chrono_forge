require "test_helper"

class AutomergeTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  # SingleSpawnWorkflow opens branch :grp with automerge: true and no explicit
  # merge call. automerge must join inline at the branch block's close, which
  # leaves a completed merge$grp log on the parent.
  def test_automerge_joins_inline_at_block_close
    SingleSpawnWorkflow.perform_later("am-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "am-1")
    assert parent.completed?, "automerge branch should be joined before completion"

    child = ChronoForge::Workflow.find_by(key: "am-1$grp$child")
    assert child.completed?

    merge_log = parent.execution_logs.find_by(step_name: "merge$grp")
    assert merge_log, "automerge must go through the inline merge_branches path (merge$grp log)"
    assert merge_log.completed?, "inline merge$grp log should be completed"
  end

  def test_unmerged_branch_raises
    UnmergedBranchWorkflow.perform_later("um-1")
    error = assert_raises(ChronoForge::Executor::UnmergedBranchError) { perform_all_jobs }
    assert_match(/forgotten/, error.message)
  end

  # The inline automerge halts inside `branch` until the branch is joined, so a
  # step that follows the branch must not run until the children are done.
  def test_automerge_blocks_subsequent_steps
    AutomergeThenStepWorkflow.perform_later("am-2")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "am-2")
    assert parent.completed?, "workflow should complete once the branch joins and :after runs"

    child = ChronoForge::Workflow.find_by(key: "am-2$grp$child")
    assert child.completed?, "spawned child should be completed"

    assert_equal true, parent.context["after"], ":after step should have run"

    merge_log = parent.execution_logs.find_by(step_name: "merge$grp")
    after_log = parent.execution_logs.find_by(step_name: "durably_execute$after")
    assert merge_log&.completed?, "inline merge$grp log should be completed"
    assert after_log&.completed?, ":after step log should be completed"
    assert_operator after_log.id, :>, merge_log.id,
      ":after must not run until the automerge branch is joined"
  end
end

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

class AutomergeThenStepWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    branch :grp, automerge: true do
      spawn :child, NoopChild
    end
    durably_execute :after
  end

  private

  def after
    context["after"] = true
  end
end
