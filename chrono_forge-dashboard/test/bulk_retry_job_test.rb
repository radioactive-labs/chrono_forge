require "test_helper"

class BulkRetryJobTest < ActiveSupport::TestCase
  include DashboardTestHelpers
  include ActiveJob::TestHelper

  test "retryable scope covers failed and stalled only" do
    create_workflow(key: "f", state: :failed)
    create_workflow(key: "s", state: :stalled)
    create_workflow(key: "c", state: :completed)
    create_workflow(key: "r", state: :running)
    assert_equal %w[f s], ChronoForge::Dashboard::BulkRetryJob.retryable.pluck(:key).sort
  end

  test "performing enqueues a retry job for each blocked workflow" do
    create_workflow(key: "f", state: :failed)
    create_workflow(key: "s", state: :stalled)
    create_workflow(key: "c", state: :completed)
    assert_enqueued_jobs 2 do
      ChronoForge::Dashboard::BulkRetryJob.perform_now
    end
  end

  test "scoped to a branch retries only that branch's blocked children" do
    parent = create_workflow(key: "p", state: :idle)
    bl = parent.execution_logs.create!(step_name: "branch$x",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.hour.ago)
    create_workflow(key: "child-failed", state: :failed, parent_execution_log_id: bl.id)
    create_workflow(key: "child-ok", state: :completed, parent_execution_log_id: bl.id)
    # A blocked workflow outside the branch must be ignored by the scoped run.
    create_workflow(key: "outsider", state: :failed)
    assert_enqueued_jobs 1 do
      ChronoForge::Dashboard::BulkRetryJob.perform_now(bl.id)
    end
  end
end
