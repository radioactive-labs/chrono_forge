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
    assert_raises(ChronoForge::Executor::UnknownBranchError) { perform_all_jobs }
  ensure
    Object.send(:remove_const, :NoBranchMergeWorkflow) if defined?(NoBranchMergeWorkflow)
  end

  def test_merge_branches_rejects_dollar_name
    bad_dollar = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor

      def perform
        branch(:a) { spawn :one, NoopChild }
        merge_branches :"a$b"
      end
    end
    Object.const_set(:DollarMergeWorkflow, bad_dollar)
    DollarMergeWorkflow.perform_later("dm-1")
    assert_raises(ChronoForge::Executor::InvalidStepName) { perform_all_jobs }
  ensure
    Object.send(:remove_const, :DollarMergeWorkflow) if defined?(DollarMergeWorkflow)
  end

  def test_merge_branches_rejects_comma_name
    bad_comma = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor

      def perform
        branch(:a) { spawn :one, NoopChild }
        merge_branches :"a,b"
      end
    end
    Object.const_set(:CommaMergeWorkflow, bad_comma)
    CommaMergeWorkflow.perform_later("cm-1")
    assert_raises(ChronoForge::Executor::InvalidStepName) { perform_all_jobs }
  ensure
    Object.send(:remove_const, :CommaMergeWorkflow) if defined?(CommaMergeWorkflow)
  end

  def test_duplicate_names_treated_as_single_branch
    # merge_branches :a, :a must dedup to :a and behave identically to merge_branches :a.
    dup_wf = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor

      def perform
        branch(:a) { spawn :one, NoopChild }
        merge_branches :a, :a
        context["done"] = true
      end
    end
    Object.const_set(:DupMergeWorkflow, dup_wf)
    DupMergeWorkflow.perform_later("dup-merge-1")
    perform_all_jobs

    wf = ChronoForge::Workflow.find_by(key: "dup-merge-1")
    assert wf.completed?, "parent should complete with deduped branch names"
    assert_equal true, wf.context["done"]
    merge_log = wf.execution_logs.find { |l| l.step_name == "merge$a" }
    assert merge_log, "merge log should be named merge$a (single, deduped)"
    assert merge_log.completed?
  ensure
    Object.send(:remove_const, :DupMergeWorkflow) if defined?(DupMergeWorkflow)
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

  def test_merge_stamps_shared_fencing_token_on_branch_logs
    TwoBranchWorkflow.perform_later("mb-token")
    # Run only the parent's first pass: it dispatches children and halts at the
    # merge after stamping the fencing token on the branch logs. The children and
    # the poller stay queued (filtered out), so we observe the post-stamp state.
    perform_enqueued_jobs(only: TwoBranchWorkflow)

    parent = ChronoForge::Workflow.find_by(key: "mb-token")
    tokens = parent.execution_logs
      .where("step_name LIKE 'branch$%'")
      .map { |l| l.metadata["poll_token"] }
    assert_equal 2, tokens.size, "both branch logs present"
    assert tokens.all?(&:present?), "each branch log carries a fencing token"
    assert_equal 1, tokens.uniq.size, "all branches in the merge share one token"
  end

  # merge_branch (singular) is an alias of merge_branches and must join a branch.
  def test_merge_branch_singular_alias_joins
    wf = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor

      def perform
        branch(:a) { spawn :one, NoopChild }
        merge_branch :a
        context["done"] = true
      end
    end
    Object.const_set(:SingularMergeWorkflow, wf)
    SingularMergeWorkflow.perform_later("singular-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "singular-1")
    assert parent.completed?, "merge_branch alias should drive the join to completion"
    assert_equal true, parent.context["done"]
    assert parent.execution_logs.find_by(step_name: "merge$a")&.completed?
  ensure
    Object.send(:remove_const, :SingularMergeWorkflow) if defined?(SingularMergeWorkflow)
  end

  # A min_interval > max_interval is rejected at the call site (in the parent), not
  # deep in the poller where the clamp would raise and dead-letter BranchMergeJob.
  def test_merge_branches_rejects_min_interval_greater_than_max
    job = SingleSpawnWorkflow.new
    assert_raises(ArgumentError) do
      job.merge_branches(:a, min_interval: 10.seconds, max_interval: 5.seconds)
    end
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
