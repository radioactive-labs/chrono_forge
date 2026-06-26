require "test_helper"

class RepetitionsQueryTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  def run_log(wf, step, ts, state:, **attrs)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$#{step}$#{ts}",
      state: ChronoForge::ExecutionLog.states[state], attempts: 1, started_at: Time.zone.at(ts), **attrs)
  end

  test "summary counts iterations and tombstones for one step only" do
    wf = create_workflow(key: "r1")
    run_log(wf, "sync", 1_717_000_000, state: :completed)
    run_log(wf, "sync", 1_717_000_600, state: :completed)
    run_log(wf, "sync", 1_717_001_200, state: :failed) # tombstone
    run_log(wf, "other", 1_717_000_000, state: :failed) # different step, excluded

    s = ChronoForge::Dashboard::RepetitionsQuery.new(workflow: wf, step: "sync").summary
    assert_equal 3, s[:iterations]
    assert_equal 2, s[:completed]
    assert_equal 1, s[:tombstones]
  end

  test "keyset paginates the runs newest id first" do
    wf = create_workflow(key: "r2")
    5.times { |i| run_log(wf, "sync", 1_717_000_000 + i * 600, state: :completed) }

    page1 = ChronoForge::Dashboard::RepetitionsQuery.new(workflow: wf, step: "sync", per: 2)
    assert_equal 2, page1.records.size
    assert page1.has_next?

    page2 = ChronoForge::Dashboard::RepetitionsQuery.new(workflow: wf, step: "sync", per: 2, before: page1.next_cursor)
    assert_equal 2, page2.records.size
    assert (page1.records.map(&:id) & page2.records.map(&:id)).empty?
  end
end

class RepetitionsControllerTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers

  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "renders the repetitions page with a tombstone labeled as such" do
    wf = create_workflow(key: "rc1", state: :running)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$digest$1717000000",
      state: ChronoForge::ExecutionLog.states[:failed], attempts: 1, error_class: "TimeoutError",
      started_at: Time.zone.at(1_717_000_000))

    get "/chrono_forge/workflows/#{wf.id}/repetitions", params: {step: "digest"}
    assert_response :success
    assert_match "Repetitions", response.body
    assert_match "tombstone", response.body
    assert_match "TimeoutError", response.body
  end

  test "shows how late a repetition started versus its scheduled time" do
    wf = create_workflow(key: "rc2", state: :running)
    ts = 1_717_000_000
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: "durably_repeat$digest$#{ts}",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1,
      started_at: Time.zone.at(ts + 120), completed_at: Time.zone.at(ts + 125))

    get "/chrono_forge/workflows/#{wf.id}/repetitions", params: {step: "digest"}
    assert_response :success
    assert_match "Late by", response.body
    assert_match "2m 00s", response.body
  end
end
