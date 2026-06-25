require "test_helper"

class WorkflowsShowTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers
  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "renders timeline, context, errors" do
    wf = create_workflow(key: "show-1", state: :failed, context: { "amount" => 10 })
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_execute$charge",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 3, started_at: 1.minute.ago, error_class: "Boom")
    ChronoForge::ErrorLog.create!(workflow: wf, step_name: "durably_execute$charge", attempt: 3,
      error_class: "Boom", error_message: "kaboom")

    get "/chrono_forge/workflows/#{wf.id}"
    assert_response :success
    assert_match "charge", response.body
    assert_match "amount", response.body
    assert_match "kaboom", response.body
  end

  test "wait callout for idle wait_until" do
    wf = create_workflow(key: "show-2", state: :idle)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "wait_until$paid?",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1,
      started_at: 2.hours.ago, last_executed_at: 2.hours.ago,
      metadata: { "timeout_at" => 1.hour.from_now })
    get "/chrono_forge/workflows/#{wf.id}"
    assert_match "cf-wait-callout", response.body
  end

  test "unknown step name renders without raising" do
    wf = create_workflow(key: "show-3", state: :running)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "legacy_thing",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    get "/chrono_forge/workflows/#{wf.id}"
    assert_response :success
    assert_match "legacy_thing", response.body
  end
end
