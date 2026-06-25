require "test_helper"

class PeriodicAndWaitTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers
  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "wait presenter detects active idle wait" do
    wf = create_workflow(key: "w1", state: :idle)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "wait_until$ready?",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1,
      started_at: 90.minutes.ago, last_executed_at: 90.minutes.ago,
      metadata: { "timeout_at" => 1.hour.from_now })
    active = ChronoForge::Dashboard::WaitStatePresenter.new(wf).active
    assert_equal "ready?", active.condition
  end

  test "wait-states index flags long waiters" do
    wf = create_workflow(key: "w2", state: :idle)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "wait_until$ready?",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1,
      started_at: 5.hours.ago, last_executed_at: 5.hours.ago, metadata: {})
    get "/chrono_forge/wait_states"
    assert_response :success
    assert_match "w2", response.body
    assert_match "cf-wait--long", response.body
  end

  test "periodic health reports timeouts and latencies" do
    wf = create_workflow(key: "p1")
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1, started_at: 1.day.ago,
      metadata: { "last_execution_at" => 2.hours.ago.iso8601 })
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync$1717000000",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 1, error_class: "TimeoutError",
      started_at: 3.hours.ago, completed_at: 3.hours.ago)
    health = ChronoForge::Dashboard::PeriodicHealthPresenter.new(wf).tasks
    assert_equal 1, health.first.timed_out_count
  end
end
