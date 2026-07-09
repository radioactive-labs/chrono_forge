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

  test "bulk retry enqueues for all failed and stalled, not others" do
    create_workflow(key: "b1", state: :failed)
    create_workflow(key: "b2", state: :stalled)
    create_workflow(key: "b3", state: :completed)
    create_workflow(key: "b4", state: :running)
    assert_enqueued_jobs 2 do
      post "/chrono_forge/workflows/bulk_retry"
    end
    assert_response :see_other
  end
end
