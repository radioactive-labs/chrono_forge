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

  test "stats header includes a blocked (failed+stalled) filter chip" do
    get "/chrono_forge/workflows"
    assert_match "blocked", response.body
    assert_match "state=blocked", response.body
  end

  test "filtering by blocked shows failed and stalled, not others" do
    create_workflow(key: "stall-1", state: :stalled)
    get "/chrono_forge/workflows", params: {state: "blocked"}
    assert_match "ord-1", response.body    # failed
    assert_match "stall-1", response.body  # stalled
    refute_match "pay-1", response.body    # completed
  end

  test "bulk retry button is labeled to match the blocked filter" do
    get "/chrono_forge/workflows"
    assert_match "Retry blocked", response.body
  end

  test "hides branch children by default, shows them when toggle is off" do
    parent = ChronoForge::Workflow.find_by!(key: "ord-1")
    branch_log = parent.execution_logs.create!(
      step_name: "branch$g", state: ChronoForge::ExecutionLog.states[:completed]
    )
    create_workflow(key: "branch-child-1", state: :idle, parent_execution_log_id: branch_log.id)

    get "/chrono_forge/workflows"
    refute_match "branch-child-1", response.body

    get "/chrono_forge/workflows", params: {hide_branches: "0"}
    assert_match "branch-child-1", response.body
  end

  test "renders the hide-branches toggle, checked by default" do
    get "/chrono_forge/workflows"
    assert_match "Hide branches", response.body
    assert_match(/name="hide_branches"[^>]*value="1"[^>]*checked/, response.body)
  end

  # The GET filter form must not inject the legacy `utf8=✓` field, which would
  # otherwise pollute the query string on every filter/toggle submit.
  test "filter form does not emit a utf8 enforcement field" do
    get "/chrono_forge/workflows"
    refute_match(/name="utf8"/, response.body)
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

  test "time format: relative by default, absolute via cookie" do
    create_workflow(key: "tf", state: :completed, started_at: 2.hours.ago)

    get "/chrono_forge/workflows"
    assert_match(/>[^<]*ago<\/span>/, response.body, "relative time is shown as text by default")

    cookies[:cf_time_format] = "absolute"
    get "/chrono_forge/workflows"
    assert_match(/title="[^"]*ago"/, response.body, "with the cookie, relative time moves to the hover title")
  end

  test "auto-refresh interval is cookie-controlled" do
    get "/chrono_forge/workflows"
    assert_match "data-poll-select", response.body

    cookies[:cf_poll_interval] = "30"
    get "/chrono_forge/workflows"
    assert_match 'data-poll-interval="30"', response.body
  end

  # The index opts into the polling morph refresh (counterpart to the definition
  # graph, which opts out). The JS gates on this attribute.
  test "index carries the data-poll-region hook" do
    get "/chrono_forge/workflows"
    assert_match(/data-poll-region/, response.body)
  end

  test "plain idle workflow stays idle, not scheduled" do
    create_workflow(key: "idle-1", state: :idle)
    get "/chrono_forge/workflows"
    assert_match "cf-pill-idle", response.body
    refute_match "cf-pill-scheduled", response.body
  end
end
