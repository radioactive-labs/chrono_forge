require "test_helper"

class WorkflowsIndexTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers

  setup do
    ChronoForge::Dashboard.configure { |c| c.authentication = :none }
    create_workflow(key: "ord-1", state: :failed, job_class: "OrderWorkflow")
    create_workflow(key: "pay-1", state: :completed, job_class: "PayoutWorkflow")
  end
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "lists workflows with badges" do
    get "/chrono_forge/workflows"
    assert_response :success
    assert_match "ord-1", response.body
    assert_match "pay-1", response.body
    assert_match "cf-pill-failed", response.body
  end

  test "filters by state" do
    get "/chrono_forge/workflows", params: {state: "failed"}
    assert_match "ord-1", response.body
    refute_match "pay-1", response.body
  end

  test "stats header shows counts" do
    get "/chrono_forge/workflows"
    assert_match "cf-stat", response.body
  end

  test "idle workflow parked on a future wait shows as scheduled" do
    wf = create_workflow(key: "sched-1", state: :idle)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "wait_until$payment_time?",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1,
      started_at: 1.hour.ago, last_executed_at: 1.hour.ago,
      metadata: {"timeout_at" => 2.hours.from_now.iso8601})
    get "/chrono_forge/workflows"
    assert_match "cf-pill-scheduled", response.body
  end

  test "plain idle workflow stays idle, not scheduled" do
    create_workflow(key: "idle-1", state: :idle)
    get "/chrono_forge/workflows"
    assert_match "cf-pill-idle", response.body
    refute_match "cf-pill-scheduled", response.body
  end
end
