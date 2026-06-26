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
      metadata: {"timeout_at" => 1.hour.from_now})
    active = ChronoForge::Dashboard::WaitStatePresenter.new(wf).active
    assert_equal "ready?", active.condition
  end

  test "active_map batch-resolves waits and flags scheduled vs overdue" do
    future = create_workflow(key: "wm1", state: :idle)
    ChronoForge::ExecutionLog.create!(workflow: future, step_name: "wait_until$ready?",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1, started_at: 1.hour.ago,
      metadata: {"timeout_at" => 1.hour.from_now.iso8601})
    overdue = create_workflow(key: "wm2", state: :idle)
    ChronoForge::ExecutionLog.create!(workflow: overdue, step_name: "wait_until$ready?",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1, started_at: 5.hours.ago,
      metadata: {"timeout_at" => 1.hour.ago.iso8601})
    plain = create_workflow(key: "wm3", state: :idle)

    map = ChronoForge::Dashboard::WaitStatePresenter.active_map([future, overdue, plain])
    assert map[future.id].scheduled?, "future wake time should read as scheduled"
    refute map[overdue.id].scheduled?, "past wake time is not scheduled"
    assert_nil map[plain.id], "idle workflow with no wait has no entry"
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
      metadata: {"last_execution_at" => 2.hours.ago.iso8601})
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync$1717000000",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 1, error_class: "TimeoutError",
      started_at: 3.hours.ago, completed_at: 3.hours.ago)
    health = ChronoForge::Dashboard::PeriodicHealthPresenter.new(wf).tasks
    assert_equal 1, health.first.timed_out_count
  end

  test "periodic health reports the next scheduled run" do
    wf = create_workflow(key: "p2")
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1, started_at: 1.day.ago,
      metadata: {"last_execution_at" => 1.hour.ago.iso8601})
    # a pending (not-yet-run) repetition scheduled for the future
    future = 2.hours.from_now.to_i
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync$#{future}",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 0)
    task = ChronoForge::Dashboard::PeriodicHealthPresenter.new(wf).tasks.first
    assert_equal Time.zone.at(future), task.next_scheduled_at
  end
end
