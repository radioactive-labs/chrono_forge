require "test_helper"

class StalledTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers

  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "lists stalled workflows with diagnostic context" do
    wf = create_workflow(key: "stuck-1", state: :stalled, job_class: "OrderWorkflow",
      locked_by: "worker-7", locked_at: 1.hour.ago)
    wf.execution_logs.create!(step_name: "durably_execute$charge_card",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 3, started_at: 1.hour.ago)
    wf.error_logs.create!(step_name: "durably_execute$charge_card", attempt: 3,
      error_class: "PaymentDeclinedError", error_message: "card declined")

    get "/chrono_forge/stalled"
    assert_response :success
    assert_match "stuck-1", response.body
    assert_match "worker-7", response.body
    assert_match "charge_card", response.body
    assert_match "PaymentDeclinedError", response.body
  end

  test "excludes non-stalled workflows" do
    create_workflow(key: "ok", state: :running)
    create_workflow(key: "done", state: :completed)
    get "/chrono_forge/stalled"
    assert_response :success
    refute_match "ok", response.body
    refute_match "done", response.body
  end

  test "shows an empty state when nothing is stalled" do
    get "/chrono_forge/stalled"
    assert_response :success
    assert_match(/No stalled workflows/i, response.body)
  end

  test "offers retry and unlock actions per row" do
    wf = create_workflow(key: "stuck-2", state: :stalled, locked_by: "w1")
    get "/chrono_forge/stalled"
    assert_match "/chrono_forge/workflows/#{wf.id}/retry", response.body
    assert_match "/chrono_forge/workflows/#{wf.id}/unlock", response.body
  end
end
