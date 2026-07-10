require "test_helper"

class StrandedTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers
  include ActiveJob::TestHelper

  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  # reap_stale_after defaults to 3x max_duration = 30 min.
  test "lists running workflows with a stale lock, not healthy or terminal ones" do
    create_workflow(key: "stranded-1", state: :running, locked_at: 40.minutes.ago, locked_by: "dead-1")
    create_workflow(key: "healthy-1", state: :running, locked_at: 1.minute.ago, locked_by: "live-1")
    create_workflow(key: "failed-1", state: :failed)

    get "/chrono_forge/stranded"
    assert_response :success
    assert_match "stranded-1", response.body
    assert_match "dead-1", response.body                       # the dead worker is named
    refute_match "healthy-1", response.body                    # fresh lock — worker alive
    refute_match "failed-1", response.body                     # not running
  end

  test "empty state when nothing is stranded" do
    create_workflow(key: "healthy", state: :running, locked_at: 1.minute.ago, locked_by: "live")
    get "/chrono_forge/stranded"
    assert_response :success
    assert_match(/No stranded workflows/i, response.body)
  end

  test "carries the poll-region hook and a reap-all action" do
    create_workflow(key: "s", state: :running, locked_at: 40.minutes.ago, locked_by: "d")
    get "/chrono_forge/stranded"
    assert_match "data-poll-region", response.body
    assert_match "/stranded/reap_all", response.body
    assert_match "Reap all stranded", response.body
  end
end

class BulkReapJobTest < ActiveSupport::TestCase
  include DashboardTestHelpers
  include ActiveJob::TestHelper

  test "reaps every stranded workflow (running with a stale lock), nothing else" do
    create_workflow(key: "s1", state: :running, locked_at: 40.minutes.ago, locked_by: "w1")
    create_workflow(key: "s2", state: :running, locked_at: 90.minutes.ago, locked_by: "w2")
    create_workflow(key: "fresh", state: :running, locked_at: 1.minute.ago, locked_by: "w3")
    create_workflow(key: "failed", state: :failed)

    assert_enqueued_jobs 2 do
      ChronoForge::Dashboard::BulkReapJob.perform_now
    end
  end
end
