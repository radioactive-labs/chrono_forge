require "test_helper"

class WorkflowsShowTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers

  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "renders timeline, context, errors" do
    wf = create_workflow(key: "show-1", state: :failed, context: {"amount" => 10})
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
      metadata: {"timeout_at" => 1.hour.from_now})
    get "/chrono_forge/workflows/#{wf.id}"
    assert_match "cf-wait-callout", response.body
  end

  test "renders periodic-task health for durably_repeat workflows" do
    wf = create_workflow(key: "show-periodic", state: :running)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 3, started_at: 1.day.ago,
      metadata: {"last_execution_at" => 2.hours.ago.iso8601})
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync$1717000000",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 1, error_class: "TimeoutError",
      started_at: 3.hours.ago, completed_at: 3.hours.ago)

    get "/chrono_forge/workflows/#{wf.id}"
    assert_response :success
    assert_match "Periodic tasks", response.body
    assert_match "sync", response.body
    assert_match "cf-periodic--timeout", response.body
  end

  test "no periodic section when there are no durably_repeat steps" do
    wf = create_workflow(key: "show-no-periodic", state: :completed)
    get "/chrono_forge/workflows/#{wf.id}"
    refute_match "Periodic tasks", response.body
  end

  test "unknown step name renders without raising" do
    wf = create_workflow(key: "show-3", state: :running)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "legacy_thing",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    get "/chrono_forge/workflows/#{wf.id}"
    assert_response :success
    assert_match "legacy_thing", response.body
  end

  test "timeline: banner names the blocker, attempts read as words, no ×1 noise" do
    wf = create_workflow(key: "show-tl", state: :stalled)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "wait_until$inventory?",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 2,
      started_at: 3.hours.ago, completed_at: 3.hours.ago)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_execute$charge",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 3, started_at: 1.hour.ago, error_class: "CardError")
    ChronoForge::ErrorLog.create!(workflow: wf, step_name: "durably_execute$charge", attempt: 3,
      error_class: "CardError", error_message: "declined")

    get "/chrono_forge/workflows/#{wf.id}"
    assert_response :success
    assert_match "Stalled at", response.body        # summary banner leads with the blocker
    assert_match "3 attempts", response.body         # a retried execution, in words
    assert_match "checked 2×", response.body         # a polled wait, labelled per kind
    refute_match "×1", response.body                 # single-attempt steps carry no marker
  end

  test "a running workflow past its threshold gets a long-running banner with a reap action" do
    wf = create_workflow(key: "show-slow", state: :running, started_at: 2.hours.ago)
    get "/chrono_forge/workflows/#{wf.id}"
    assert_response :success
    assert_match(/longer than expected/i, response.body)
    assert_match(/may be stuck/i, response.body)
    assert_match "/workflows/#{wf.id}/reap", response.body   # reap is offered where the stall is surfaced
    assert_match "Reap", response.body
  end

  test "a running workflow offers reap; a terminal one does not" do
    running = create_workflow(key: "show-run", state: :running)
    get "/chrono_forge/workflows/#{running.id}"
    assert_match "/workflows/#{running.id}/reap", response.body

    done = create_workflow(key: "show-done", state: :completed)
    get "/chrono_forge/workflows/#{done.id}"
    refute_match "/workflows/#{done.id}/reap", response.body
  end

  test "a fresh running workflow is not flagged long-running" do
    wf = create_workflow(key: "show-fresh", state: :running, started_at: 2.minutes.ago)
    get "/chrono_forge/workflows/#{wf.id}"
    assert_response :success
    refute_match(/longer than expected/i, response.body)
  end
end
