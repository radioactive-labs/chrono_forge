require "test_helper"

class ActionsTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers
  include ActiveJob::TestHelper

  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "retry enqueues a job for a failed workflow" do
    wf = create_workflow(key: "r1", state: :failed)
    assert_enqueued_jobs 1 do
      post "/chrono_forge/workflows/#{wf.id}/retry"
    end
    # 303 (not 302) so Turbo follows the redirect with GET after the POST.
    assert_response :see_other
  end

  test "retry on a running workflow flashes instead of 500" do
    wf = create_workflow(key: "r2", state: :running)
    assert_no_enqueued_jobs do
      post "/chrono_forge/workflows/#{wf.id}/retry"
    end
    assert_response :see_other
    follow_redirect!
    assert_match(/cannot retry|not.*retry/i, response.body)
    # Rendered as a floating, auto-dismissing toast (out of document flow).
    assert_match "data-flash", response.body
    assert_match "fixed", response.body
  end

  test "resume re-enqueues an idle (parked) workflow" do
    wf = create_workflow(key: "rs1", state: :idle)
    assert_enqueued_jobs 1 do
      post "/chrono_forge/workflows/#{wf.id}/resume"
    end
    assert_response :see_other
  end

  test "resume rejects a non-idle workflow" do
    wf = create_workflow(key: "rs2", state: :completed)
    assert_no_enqueued_jobs do
      post "/chrono_forge/workflows/#{wf.id}/resume"
    end
    follow_redirect!
    assert_match(/only idle/i, response.body)
  end

  test "unlock clears the lock and idles" do
    wf = create_workflow(key: "u1", state: :running, locked_at: Time.current, locked_by: "job-1")
    post "/chrono_forge/workflows/#{wf.id}/unlock"
    wf.reload
    assert_nil wf.locked_at
    assert_nil wf.locked_by
    assert wf.idle?
  end

  test "reap re-enqueues a workflow stranded in running" do
    wf = create_workflow(key: "reap1", state: :running, locked_at: 3.hours.ago, locked_by: "dead-worker")
    assert_enqueued_jobs 1 do
      post "/chrono_forge/workflows/#{wf.id}/reap"
    end
    assert_response :see_other
    follow_redirect!
    assert_match(/reaped/i, response.body)
  end

  test "reap rejects a non-running workflow" do
    wf = create_workflow(key: "reap2", state: :failed)
    assert_no_enqueued_jobs do
      post "/chrono_forge/workflows/#{wf.id}/reap"
    end
    assert_response :see_other
    follow_redirect!
    assert_match(/only running/i, response.body)
  end

  # The retries are fanned out by a single background job so the request returns
  # fast even with thousands of blocked workflows — the POST enqueues one job.
  test "bulk retry enqueues a single background job and reports the count" do
    create_workflow(key: "b1", state: :failed)
    create_workflow(key: "b2", state: :stalled)
    create_workflow(key: "b3", state: :completed)
    create_workflow(key: "b4", state: :running)
    assert_enqueued_with(job: ChronoForge::Dashboard::BulkRetryJob) do
      post "/chrono_forge/workflows/bulk_retry"
    end
    assert_response :see_other
    follow_redirect!
    assert_match(/Retrying 2 blocked/, response.body)
  end

  test "bulk retry with nothing blocked enqueues no job" do
    create_workflow(key: "ok", state: :completed)
    assert_no_enqueued_jobs do
      post "/chrono_forge/workflows/bulk_retry"
    end
    assert_response :see_other
    follow_redirect!
    assert_match(/no blocked workflows/i, response.body)
  end

  test "branch bulk retry enqueues a background job scoped to the branch" do
    parent = create_workflow(key: "bp", state: :idle)
    bl = parent.execution_logs.create!(step_name: "branch$x",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.hour.ago)
    create_workflow(key: "bc", state: :failed, parent_execution_log_id: bl.id)
    assert_enqueued_with(job: ChronoForge::Dashboard::BulkRetryJob, args: [bl.id]) do
      post "/chrono_forge/workflows/#{parent.id}/branches/#{bl.id}/bulk_retry"
    end
    assert_response :see_other
  end
end
