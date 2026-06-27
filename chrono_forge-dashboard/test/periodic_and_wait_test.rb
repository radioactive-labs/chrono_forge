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

  test "active_map surfaces continue_if event waits (no timeout, never scheduled)" do
    wf = create_workflow(key: "evt1", state: :idle)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "continue_if$webhook_received",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1,
      started_at: 3.hours.ago, last_executed_at: 3.hours.ago, metadata: {})

    active = ChronoForge::Dashboard::WaitStatePresenter.active_map([wf])[wf.id]
    assert_equal :continue, active.kind
    assert active.event_wait?
    refute active.scheduled?, "an event wait has no future wake time"
  end

  test "wait-states page leads with oldest unresolved event wait per class" do
    old = create_workflow(key: "evt-old", state: :idle, job_class: "PayoutWorkflow")
    ChronoForge::ExecutionLog.create!(workflow: old, step_name: "continue_if$payout_callback",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1,
      started_at: 12.hours.ago, last_executed_at: 12.hours.ago, metadata: {})

    get "/chrono_forge/wait_states"
    assert_response :success
    assert_match "Oldest unresolved event wait", response.body
    assert_match "payout_callback", response.body
    assert_match "PayoutWorkflow", response.body
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

  test "periodic health counts a fast-forward summary as its N missed ticks" do
    wf = create_workflow(key: "pff")
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1, started_at: 1.day.ago,
      metadata: {"last_execution_at" => 2.hours.ago.iso8601})
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync$1717000000",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 1, error_class: "TimeoutError",
      started_at: 3.hours.ago, completed_at: 3.hours.ago) # legacy per-tick → 1
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$sync$1717003600",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 1, error_class: "TimeoutError",
      started_at: 2.hours.ago, completed_at: 2.hours.ago,
      metadata: {"fast_forwarded" => 30}) # collapsed → 30
    health = ChronoForge::Dashboard::PeriodicHealthPresenter.new(wf).tasks
    assert_equal 31, health.first.timed_out_count
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
