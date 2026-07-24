require "test_helper"

class CleanupJobTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def test_job_runs_cleanup
    old = ChronoForge::Workflow.create!(
      key: "job_cleanup", job_class: "KitchenSink",
      kwargs: {}, options: {}, context: {}, state: :completed
    )
    old.update_column(:completed_at, 100.days.ago)

    ChronoForge::CleanupJob.perform_now(older_than_days: 90)

    refute ChronoForge::Workflow.exists?(old.id), "cleanup job should delete the old terminal workflow"
  end

  def test_job_accepts_scalar_args_for_config_based_scheduling
    # Simulate args coming from a YAML/cron config (strings/integers, never
    # ActiveSupport::Duration objects which cannot be expressed in config).
    old = ChronoForge::Workflow.create!(
      key: "scalar_cleanup", job_class: "KitchenSink",
      kwargs: {}, options: {}, context: {}, state: :failed
    )
    old.update_column(:updated_at, 100.days.ago)

    ChronoForge::CleanupJob.perform_now(failed_older_than_days: 90, batch_size: 500)

    refute ChronoForge::Workflow.exists?(old.id)
  end

  def test_job_is_enqueueable
    assert_nothing_raised do
      ChronoForge::CleanupJob.perform_later
    end
  end

  # Cleanup is deferrable housekeeping — read the queue per-enqueue from config so an
  # operator can push pruning onto an off-peak queue without redefining the class.
  # Defaults to :default (unlike branch_merge_queue, this job is never latency-critical).
  def test_cleanup_queue_is_configurable
    ChronoForge.reset_configuration!
    assert_equal "default", ChronoForge::CleanupJob.new.queue_name
    ChronoForge.configure { |c| c.maintenance_queue = :chrono_forge_maintenance }
    assert_equal "chrono_forge_maintenance", ChronoForge::CleanupJob.new.queue_name
  ensure
    ChronoForge.reset_configuration!
  end
end
