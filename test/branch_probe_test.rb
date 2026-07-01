require "test_helper"

class BranchProbeTest < ActiveSupport::TestCase
  def setup
    ChronoForge::Workflow.where(key: "bp-parent").destroy_all
    @parent = ChronoForge::Workflow.create!(key: "bp-parent", job_class: "SingleSpawnWorkflow")
    @log = @parent.execution_logs.create!(step_name: "branch$g", state: :completed)
  end

  def child!(state:, started_at: Time.current)
    ChronoForge::Workflow.create!(
      key: "bpc-#{SecureRandom.hex}", job_class: "NoopChild",
      parent_execution_log_id: @log.id, state: state, started_at: started_at
    )
  end

  # "Progressing" = a child that can move forward on its own: actively running, or
  # dispatched-but-not-yet-started (started_at nil). These — and only these —
  # justify the fast count-based poll cadence.
  def test_progressing_counts_running_and_never_started_idle
    child!(state: :running)
    child!(state: :idle, started_at: nil)
    assert_equal 2, ChronoForge::BranchProbe.progressing(@log.id).count
  end

  # Waiting (idle with started_at SET — parked on a wait/wait_until), blocked
  # (failed/stalled — needs operator recovery), and completed children are NOT
  # progressing: none will advance on the poller's account, so they must not pin
  # the cadence at the responsive floor.
  def test_progressing_excludes_waiting_blocked_and_completed
    child!(state: :idle, started_at: 1.minute.ago) # parked on a wait
    child!(state: :failed)
    child!(state: :stalled)
    child!(state: :completed)
    assert_equal 0, ChronoForge::BranchProbe.progressing(@log.id).count
  end

  # incomplete still counts blocked + waiting (they keep the branch open); only the
  # cadence ignores them. Guards against accidentally narrowing incomplete.
  def test_incomplete_still_counts_blocked_and_waiting
    child!(state: :failed)
    child!(state: :stalled)
    child!(state: :idle, started_at: 1.minute.ago)
    child!(state: :completed)
    assert_equal 3, ChronoForge::BranchProbe.incomplete(@log.id).count
  end

  # running? — true iff a child is actively executing (drives the cadence's
  # :running motion, which holds the responsive floor). A dispatched-but-unstarted
  # or waiting/blocked child is NOT running.
  def test_running_predicate
    refute ChronoForge::BranchProbe.running?(@log.id)
    child!(state: :idle, started_at: nil) # dispatched, not started
    refute ChronoForge::BranchProbe.running?(@log.id)
    child!(state: :running)
    assert ChronoForge::BranchProbe.running?(@log.id)
  end

  # never_started? — true iff a child is idle with started_at nil (dispatched but no
  # worker has started it — the :never_started motion). A running child, or an idle
  # child that already ran and is parked on a wait (started_at SET), is NOT it.
  def test_never_started_predicate
    refute ChronoForge::BranchProbe.never_started?(@log.id)
    child!(state: :running)
    refute ChronoForge::BranchProbe.never_started?(@log.id)
    child!(state: :idle, started_at: 1.minute.ago) # ran, now waiting
    refute ChronoForge::BranchProbe.never_started?(@log.id)
    child!(state: :idle, started_at: nil) # dispatched, never started
    assert ChronoForge::BranchProbe.never_started?(@log.id)
  end
end
