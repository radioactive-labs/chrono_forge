require "test_helper"

class MergeBranchesTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def test_parent_resumes_after_branches_complete
    TwoBranchWorkflow.perform_later("mb-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "mb-1")
    assert parent.completed?, "parent should complete once both branches merge"
    assert_equal true, parent.context["finalized"]
    merge_log = parent.execution_logs.find { |l| l.step_name.start_with?("merge$") }
    assert merge_log.completed?
  end

  def test_unopened_branch_name_raises
    job = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      def perform = merge_branches(:nope)
    end
    Object.const_set(:NoBranchMergeWorkflow, job)
    NoBranchMergeWorkflow.perform_later("nb-1")
    assert_raises(ArgumentError) { perform_all_jobs }
  ensure
    Object.send(:remove_const, :NoBranchMergeWorkflow) if defined?(NoBranchMergeWorkflow)
  end

  def test_incomplete_child_keeps_parent_parked
    # StalledBranchWorkflow has branch :a (stalling child) and branch :b (noop).
    # The stalling child raises on every attempt and exhausts retries → failed.
    # BranchMergeJob counts failed children as "pending" (Option A: only
    # :completed is done), so the parent stays parked. We bound the time window
    # so perform_all_jobs_before stops after the BMJ has rescheduled once (5s
    # wait), giving us a deterministic assertion without hanging.
    StalledBranchWorkflow.perform_later("sb-1")

    # Run enough to: (a) execute parent, (b) run both children, (c) run the
    # first BranchMergeJob poll (enqueued immediately with no wait). The BMJ
    # finds a failed (non-:completed) child and reschedules itself with a 5s
    # wait — which is beyond 4s, so the loop terminates.
    perform_all_jobs_before(4.seconds)

    parent = ChronoForge::Workflow.find_by(key: "sb-1")
    refute parent.completed?, "parent should NOT be completed while a child is failed"
    assert_nil parent.context["finalized"], "finalize step must not run while merge is parked"

    merge_log = parent.execution_logs.find { |l| l.step_name.start_with?("merge$") }
    refute merge_log&.completed?, "merge log must not be completed while a child is failed"

    # Confirm the stalling child really did fail (not stalled, which would be a
    # different workflow-level failure mode).
    child_key = "sb-1$a$bad"
    bad_child = ChronoForge::Workflow.find_by(key: child_key)
    assert bad_child, "stalling child workflow should exist"
    assert bad_child.failed?, "stalling child should be in failed state"
  end
end

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A child that always raises → exhausts workflow-level retries → ends up failed.
# max_attempts: 1 means exactly one attempt, no retry jobs → terminates fast.
class StallingChild < WorkflowJob
  prepend ChronoForge::Executor
  retry_policy max_attempts: 1

  def perform(**)
    raise "stalling child always fails"
  end
end

class StalledBranchWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    branch :a do
      spawn :bad, StallingChild
    end
    branch :b do
      spawn :good, NoopChild
    end
    merge_branches :a, :b
    durably_execute :finalize
  end

  private

  def finalize
    context["finalized"] = true
  end
end
