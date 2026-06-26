require "test_helper"

class BranchIntegrationTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
    User.delete_all
  end

  # -------------------------------------------------------------------------
  # Test 1: Empty spawn_each source
  #
  # When User.all is empty the branch block runs but spawn_each dispatches
  # nothing.  The branch must still seal and automerge inline so the parent
  # can complete.
  # -------------------------------------------------------------------------
  def test_empty_spawn_each_source_seals_and_completes
    SpawnEachWorkflow.perform_later("empty-src-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "empty-src-1")
    assert parent.completed?, "parent should complete when source is empty"

    branch_log = parent.execution_logs.find_by(step_name: "branch$grp")
    assert branch_log, "branch$grp execution log must exist"
    assert branch_log.completed?, "branch$grp log must be sealed (completed)"

    child_count = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id).count
    assert_equal 0, child_count, "no children should have been spawned for an empty source"
  end

  # -------------------------------------------------------------------------
  # Test 2: Empty branch body (no spawns)
  #
  # A branch block that contains no spawn calls must still seal via automerge
  # and allow execution to continue to the next step.
  # -------------------------------------------------------------------------
  def test_empty_branch_body_resolves_immediately_and_continues
    job_klass = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor

      def perform
        branch :empty, automerge: true do
          # no spawns
        end
        durably_execute :after
      end

      private

      def after
        context["after"] = true
      end
    end
    Object.const_set(:EmptyBranchWorkflow, job_klass)

    EmptyBranchWorkflow.perform_later("empty-branch-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "empty-branch-1")
    assert parent.completed?, "parent should complete after empty automerge branch"
    assert_equal true, parent.context["after"],
      ":after step must run once the empty branch resolves"
  ensure
    Object.send(:remove_const, :EmptyBranchWorkflow) if defined?(EmptyBranchWorkflow)
  end

  # -------------------------------------------------------------------------
  # Test 3: Nested branches (child workflow opens its own branch)
  #
  # NestingParentWorkflow
  #   branch :top, automerge: true
  #     spawn :c, NestingChild          → key: "nest-1$top$c"
  #
  # NestingChild
  #   branch :sub, automerge: true
  #     spawn :gc, NoopChild            → key: "nest-1$top$c$sub$gc"
  #
  # The multi-level automerge poll cascade must drain fully so the whole
  # tree reaches :completed bottom-up.
  # -------------------------------------------------------------------------
  def test_nested_branches_complete_bottom_up
    NestingParentWorkflow.perform_later("nest-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "nest-1")
    assert parent.completed?, "top-level parent should complete"

    child = ChronoForge::Workflow.find_by(key: "nest-1$top$c")
    assert child, "NestingChild workflow row must exist"
    assert child.completed?, "NestingChild should complete"

    grandchild = ChronoForge::Workflow.find_by(key: "nest-1$top$c$sub$gc")
    assert grandchild, "NoopChild (grandchild) workflow row must exist"
    assert grandchild.completed?, "NoopChild grandchild should complete"
  end
end
