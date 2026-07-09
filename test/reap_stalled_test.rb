require "test_helper"

# Reaper for workflows stranded in :running by a hard-killed worker (SIGKILL/OOM/
# eviction) whose `ensure` block never ran — so the lock was never released and no
# resume continuation was ever published. See
# docs/superpowers/specs/2026-07-09-chrono-forge-reaper-design.md.
class ReapStalledTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
    ChronoForge.reset_configuration!
  end

  def teardown
    ChronoForge.reset_configuration!
  end

  # Build a workflow row directly in the stranded shape: :running with an old
  # locked_at and NO scheduled resume job — exactly what a hard-killed pass leaves
  # behind (ensure never ran, so release_lock/flush_continuation never happened).
  def stranded_workflow(key:, locked_at:, job_class: "ReapTestJob", **attrs)
    ChronoForge::Workflow.create!(
      key: key, job_class: job_class, kwargs: {}, options: {}, context: {},
      state: :running, locked_by: "dead-job-#{key}", locked_at: locked_at,
      started_at: 1.hour.ago, **attrs
    )
  end

  def test_reaps_running_workflow_with_stale_lock
    wf = stranded_workflow(key: "stranded_1", locked_at: 40.minutes.ago)

    assert_difference -> { enqueued_jobs.size }, 1 do
      assert_equal 1, ChronoForge::Workflow.reap_stalled
    end

    assert(enqueued_jobs.any? { |j| j.to_s.include?(wf.key) },
      "reap must re-enqueue a job targeting the stranded workflow's key")
  end

  def test_does_not_reap_running_workflow_with_fresh_lock
    # A lock younger than the threshold is a genuinely-live (or recently-live) pass.
    stranded_workflow(key: "fresh_lock", locked_at: 2.minutes.ago)

    assert_no_difference -> { enqueued_jobs.size } do
      assert_equal 0, ChronoForge::Workflow.reap_stalled
    end
  end

  def test_does_not_reap_non_running_states
    ChronoForge::Workflow.create!(key: "idle_wf", job_class: "ReapTestJob", kwargs: {}, options: {},
      context: {}, state: :idle)
    ChronoForge::Workflow.create!(key: "completed_wf", job_class: "ReapTestJob", kwargs: {}, options: {},
      context: {}, state: :completed, completed_at: 40.minutes.ago)
    ChronoForge::Workflow.create!(key: "failed_wf", job_class: "ReapTestJob", kwargs: {}, options: {},
      context: {}, state: :failed)
    ChronoForge::Workflow.create!(key: "stalled_wf", job_class: "ReapTestJob", kwargs: {}, options: {},
      context: {}, state: :stalled)

    assert_no_difference -> { enqueued_jobs.size } do
      assert_equal 0, ChronoForge::Workflow.reap_stalled
    end
  end

  def test_does_not_reap_running_workflow_with_null_locked_at
    # An anomalous running-without-lock row must not match `locked_at < ?`.
    stranded_workflow(key: "null_lock", locked_at: nil)

    assert_no_difference -> { enqueued_jobs.size } do
      assert_equal 0, ChronoForge::Workflow.reap_stalled
    end
  end

  def test_reaps_branch_child_not_only_top_level
    # Branch children hard-killed mid-pass are :running with a stale lock too, and
    # BranchMergeJob rekick does NOT recover them (it only re-enqueues never-started
    # idle children). The reaper must sweep them like any other stranded workflow.
    parent = stranded_workflow(key: "parent_wf", locked_at: 40.minutes.ago)
    parent_log = ChronoForge::ExecutionLog.create!(
      workflow: parent, step_name: "branch$b", state: :pending
    )
    child = stranded_workflow(key: "child_wf", locked_at: 40.minutes.ago,
      parent_execution_log_id: parent_log.id)

    ChronoForge::Workflow.reap_stalled

    assert(enqueued_jobs.any? { |j| j.to_s.include?(child.key) },
      "reap must re-enqueue a stranded branch child, not just top-level workflows")
  end

  def test_per_row_failure_does_not_abort_the_sweep
    # One row that raises on re-enqueue (e.g. an unconstantizable job_class from a
    # since-deleted workflow class) must not sink the whole sweep.
    stranded_workflow(key: "bad_row", locked_at: 40.minutes.ago, job_class: "NoSuchWorkflowClass")
    good = stranded_workflow(key: "good_row", locked_at: 40.minutes.ago)

    reaped = nil
    assert_nothing_raised { reaped = ChronoForge::Workflow.reap_stalled }

    assert_equal 1, reaped, "count must reflect only successful re-enqueues"
    assert(enqueued_jobs.any? { |j| j.to_s.include?(good.key) },
      "the healthy row must still be reaped despite the bad row")
  end

  def test_stale_after_override_is_honored
    stranded_workflow(key: "override_wf", locked_at: 20.minutes.ago)

    # Default 30.min would NOT catch a 20-min-old lock...
    assert_equal 0, ChronoForge::Workflow.reap_stalled

    # ...but an explicit shorter threshold does.
    assert_difference -> { enqueued_jobs.size }, 1 do
      assert_equal 1, ChronoForge::Workflow.reap_stalled(stale_after: 10.minutes)
    end
  end

  def test_reap_stale_after_is_configurable
    stranded_workflow(key: "configured_wf", locked_at: 20.minutes.ago)

    ChronoForge.configure { |c| c.reap_stale_after = 15.minutes }

    assert_difference -> { enqueued_jobs.size }, 1 do
      assert_equal 1, ChronoForge::Workflow.reap_stalled
    end
  end

  def test_default_max_duration_is_ten_minutes
    assert_equal 10.minutes, ChronoForge.config.max_duration
  end

  def test_default_reap_stale_after_is_thirty_minutes
    # Derives from max_duration (3x) so it always clears the lock-steal threshold.
    assert_equal 30.minutes, ChronoForge.config.reap_stale_after
  end

  def test_reap_stale_after_derives_from_configured_max_duration
    ChronoForge.configure { |c| c.max_duration = 20.minutes }
    assert_equal 60.minutes, ChronoForge.config.reap_stale_after,
      "reap_stale_after should track max_duration when not explicitly set"
  end

  def test_explicit_reap_stale_after_overrides_the_derived_default
    ChronoForge.configure do |c|
      c.max_duration = 20.minutes
      c.reap_stale_after = 45.minutes
    end
    assert_equal 45.minutes, ChronoForge.config.reap_stale_after
  end

  def test_executor_max_duration_reads_from_config
    ChronoForge.configure { |c| c.max_duration = 3.minutes }
    assert_equal 3.minutes, ReapTestJob.new.send(:max_duration),
      "executor#max_duration should read from ChronoForge.config"
  end

  # End-to-end: a stranded workflow, once reaped, actually resumes and completes
  # when the queue is drained — acquire_lock steals the stale lock and the pass runs.
  def test_reaped_workflow_resumes_and_completes
    wf = stranded_workflow(key: "recover_me", locked_at: 40.minutes.ago)

    ChronoForge::Workflow.reap_stalled
    perform_all_jobs

    wf.reload
    assert wf.completed?, "reaped workflow should resume and complete"
    assert_equal true, wf.context["ran"], "the workflow body should have executed on resume"
    assert_nil wf.locked_by, "lock should be released after the recovered pass"
  end
end

class ReapTestJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context[:ran] = true
  end
end
