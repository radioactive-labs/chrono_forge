require "test_helper"

class BranchMergeJobTest < ActiveJob::TestCase
  def setup
    ChronoForge::Workflow.where(key: "bmj-parent").destroy_all
    @parent = ChronoForge::Workflow.create!(key: "bmj-parent", job_class: "SingleSpawnWorkflow")
    @log = @parent.execution_logs.create!(step_name: "branch$g", state: :completed)
  end

  def child!(state:, started_at: Time.current)
    ChronoForge::Workflow.create!(
      key: "c-#{SecureRandom.hex}", job_class: "NoopChild",
      parent_execution_log_id: @log.id, state: state, started_at: started_at
    )
  end

  def test_wakes_parent_when_all_complete
    child!(state: :completed)
    assert_enqueued_with(job: SingleSpawnWorkflow, args: ["bmj-parent"]) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  def test_reschedules_when_incomplete
    child!(state: :running)
    assert_enqueued_with(job: ChronoForge::BranchMergeJob) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
    assert_no_enqueued_jobs(only: SingleSpawnWorkflow)
  end

  def test_does_not_wake_when_branch_not_sealed
    unsealed = @parent.execution_logs.create!(step_name: "branch$h", state: :pending)
    # children all complete, but branch not sealed yet
    ChronoForge::Workflow.create!(key: "c-x", job_class: "NoopChild",
      parent_execution_log_id: unsealed.id, state: :completed, started_at: Time.current)
    assert_enqueued_with(job: ChronoForge::BranchMergeJob) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [unsealed.id], 5, 300)
    end
    assert_no_enqueued_jobs(only: SingleSpawnWorkflow)
  end

  def test_rekicks_never_started_child
    stuck = child!(state: :idle, started_at: nil)
    stuck.update_column(:updated_at, 10.minutes.ago)
    assert_enqueued_with(job: NoopChild, args: [stuck.key]) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
  end

  def test_does_not_rekick_running_child
    running = child!(state: :running, started_at: nil)
    running.update_column(:updated_at, 10.minutes.ago)
    assert_enqueued_with(job: ChronoForge::BranchMergeJob) do
      ChronoForge::BranchMergeJob.perform_now("bmj-parent", "SingleSpawnWorkflow", [@log.id], 5, 300)
    end
    assert_no_enqueued_jobs(only: NoopChild)
  end
end
