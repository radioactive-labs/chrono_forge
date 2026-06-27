require "test_helper"

class AnalyticsQueryTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  def completed(key:, started:, finished:, job_class: "OrderWorkflow")
    wf = create_workflow(key: key, state: :completed, job_class: job_class,
      started_at: started, completed_at: finished)
    wf.update_columns(updated_at: finished)
    wf
  end

  def failed(key:, at:, job_class: "OrderWorkflow")
    wf = create_workflow(key: key, state: :failed, job_class: job_class, started_at: at)
    wf.update_columns(updated_at: at)
    wf
  end

  test "totals: workflow-level completion and failure rate over the window" do
    completed(key: "c1", started: 2.hours.ago, finished: 1.hour.ago)
    completed(key: "c2", started: 2.hours.ago, finished: 1.hour.ago)
    completed(key: "c3", started: 2.hours.ago, finished: 1.hour.ago)
    failed(key: "f1", at: 1.hour.ago)

    t = ChronoForge::Dashboard::AnalyticsQuery.new(window: "7d").totals
    assert_equal 3, t[:completed]
    assert_equal 1, t[:failed]
    assert_equal 4, t[:terminal]
    assert_in_delta 0.75, t[:completion_rate], 0.001
    assert_in_delta 0.25, t[:failure_rate], 0.001
  end

  test "average duration is computed for completed workflows only" do
    completed(key: "c1", started: 100.seconds.ago, finished: Time.current) # ~100s
    failed(key: "f1", at: 1.hour.ago)

    t = ChronoForge::Dashboard::AnalyticsQuery.new(window: "7d").totals
    assert_in_delta 100, t[:avg_duration], 5
  end

  test "window excludes terminal workflows outside the range" do
    completed(key: "recent", started: 2.hours.ago, finished: 1.hour.ago)
    completed(key: "old", started: 40.days.ago, finished: 40.days.ago)

    t = ChronoForge::Dashboard::AnalyticsQuery.new(window: "30d").totals
    assert_equal 1, t[:completed], "40-day-old workflow must fall outside the 30d window"
  end

  test "job_class scopes the metrics" do
    completed(key: "o1", started: 2.hours.ago, finished: 1.hour.ago, job_class: "OrderWorkflow")
    completed(key: "p1", started: 2.hours.ago, finished: 1.hour.ago, job_class: "PayoutWorkflow")

    t = ChronoForge::Dashboard::AnalyticsQuery.new(window: "7d", job_class: "PayoutWorkflow").totals
    assert_equal 1, t[:completed]
  end

  test "buckets group terminal workflows per day, oldest first" do
    completed(key: "c1", started: 2.hours.ago, finished: 1.hour.ago)
    failed(key: "f1", at: 1.hour.ago)

    buckets = ChronoForge::Dashboard::AnalyticsQuery.new(window: "7d").buckets
    assert_equal 1, buckets.size
    assert_equal 1, buckets.first.completed
    assert_equal 1, buckets.first.failed
    assert_equal 2, buckets.first.terminal
  end

  test "empty window yields nil rates, not a divide-by-zero" do
    t = ChronoForge::Dashboard::AnalyticsQuery.new(window: "24h").totals
    assert_nil t[:completion_rate]
    assert_nil t[:failure_rate]
    assert_equal 0, t[:terminal]
  end

  test "unknown window falls back to the default" do
    q = ChronoForge::Dashboard::AnalyticsQuery.new(window: "bogus")
    assert_equal ChronoForge::Dashboard::AnalyticsQuery::DEFAULT_WINDOW, q.window
  end

  test "top_errors counts error classes in window, highest first, scoped by class" do
    o = create_workflow(key: "oe", state: :failed, job_class: "OrderWorkflow")
    p = create_workflow(key: "pe", state: :failed, job_class: "PayoutWorkflow")
    ChronoForge::ErrorLog.create!(workflow: o, error_class: "Boom", error_message: "x")
    ChronoForge::ErrorLog.create!(workflow: o, error_class: "Boom", error_message: "y")
    ChronoForge::ErrorLog.create!(workflow: p, error_class: "Splat", error_message: "z")

    all = ChronoForge::Dashboard::AnalyticsQuery.new(window: "7d").top_errors
    assert_equal 2, all["Boom"]
    assert_equal 1, all["Splat"]
    assert_equal "Boom", all.keys.first # highest first

    scoped = ChronoForge::Dashboard::AnalyticsQuery.new(window: "7d", job_class: "OrderWorkflow").top_errors
    assert_equal({"Boom" => 2}, scoped)
  end
end

class AnalyticsControllerTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers

  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "renders the analytics page" do
    wf = create_workflow(key: "c1", state: :completed, started_at: 2.hours.ago, completed_at: 1.hour.ago)
    wf.update_columns(updated_at: 1.hour.ago)
    get "/chrono_forge/analytics"
    assert_response :success
    assert_match "Completion rate", response.body
    assert_match "Workflow failure rate", response.body
  end

  test "renders class-scoped analytics" do
    get "/chrono_forge/analytics", params: {class: "OrderWorkflow"}
    assert_response :success
    assert_match "OrderWorkflow", response.body
  end

  test "class-scoped analytics shows queue health and top errors" do
    wf = create_workflow(key: "q1", state: :running, job_class: "OrderWorkflow")
    ChronoForge::ErrorLog.create!(workflow: wf, error_class: "Boom", error_message: "x")
    get "/chrono_forge/analytics", params: {class: "OrderWorkflow"}
    assert_response :success
    assert_match "Queue health", response.body
    assert_match "Top error classes", response.body
    assert_match "Boom", response.body
  end

  test "global analytics omits the per-class queue panel" do
    get "/chrono_forge/analytics"
    assert_response :success
    refute_match "Queue health", response.body
  end
end
