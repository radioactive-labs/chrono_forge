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
    assert_response :redirect
  end

  test "retry on a running workflow flashes instead of 500" do
    wf = create_workflow(key: "r2", state: :running)
    assert_no_enqueued_jobs do
      post "/chrono_forge/workflows/#{wf.id}/retry"
    end
    assert_response :redirect
    follow_redirect!
    assert_match(/cannot retry|not.*retry/i, response.body)
  end

  test "unlock clears the lock and idles" do
    wf = create_workflow(key: "u1", state: :running, locked_at: Time.current, locked_by: "job-1")
    post "/chrono_forge/workflows/#{wf.id}/unlock"
    wf.reload
    assert_nil wf.locked_at
    assert_nil wf.locked_by
    assert wf.idle?
  end

  test "bulk retry enqueues for all failed" do
    create_workflow(key: "b1", state: :failed)
    create_workflow(key: "b2", state: :failed)
    create_workflow(key: "b3", state: :completed)
    assert_enqueued_jobs 2 do
      post "/chrono_forge/workflows/bulk_retry"
    end
  end
end
