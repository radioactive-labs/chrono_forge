require "test_helper"

class OverviewTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers

  setup do
    ChronoForge::Dashboard.configure { |c| c.authentication = :none }
    # OrderWorkflow: 3 processed, 1 in-flight, 1 blocked
    3.times { |i| create_workflow(key: "ord-done-#{i}", state: :completed, job_class: "OrderWorkflow") }
    create_workflow(key: "ord-run", state: :running, job_class: "OrderWorkflow")
    create_workflow(key: "ord-fail", state: :failed, job_class: "OrderWorkflow")
    # PayoutWorkflow: 1 processed, 1 in-flight (idle), 0 blocked
    create_workflow(key: "pay-done", state: :completed, job_class: "PayoutWorkflow")
    create_workflow(key: "pay-idle", state: :idle, job_class: "PayoutWorkflow")
  end
  teardown { ChronoForge::Dashboard.reset_configuration! }

  # --- shell -----------------------------------------------------------------

  test "index renders a lightweight shell of turbo-frames, one per section" do
    get "/chrono_forge/overview"
    assert_response :success
    assert_match(/<turbo-frame id="cf-ov-processed" src="[^"]*overview\/processed"/, response.body)
    assert_match(/<turbo-frame id="cf-ov-in-flight" src="[^"]*overview\/in_flight"/, response.body)
    assert_match(/<turbo-frame id="cf-ov-blocked" src="[^"]*overview\/blocked"/, response.body)
    assert_match(/<turbo-frame id="cf-ov-classes" src="[^"]*overview\/classes"/, response.body)
  end

  test "the shell does no aggregation itself — no class names or counts inline" do
    get "/chrono_forge/overview"
    refute_match "OrderWorkflow", response.body   # that's the table frame's job
  end

  test "the shell opts out of the polling morph region" do
    get "/chrono_forge/overview"
    refute_match(/data-poll-region/, response.body)
  end

  # Frame content is all links (whole-card, class names, counts) that must break
  # out to a full-page visit; without target="_top" they resolve inside the frame
  # and Turbo reports "content missing".
  test "every shell frame targets _top so inner links navigate the full page" do
    get "/chrono_forge/overview"
    %w[cf-ov-processed cf-ov-in-flight cf-ov-blocked cf-ov-classes].each do |id|
      assert_match(/<turbo-frame id="#{id}"[^>]*target="_top"/, response.body, "#{id} must target _top")
    end
  end

  # --- card frames -----------------------------------------------------------

  test "processed frame: count + drill-in, wrapped in its matching frame" do
    get "/chrono_forge/overview/processed"
    assert_response :success
    assert_match(/<turbo-frame id="cf-ov-processed">/, response.body)
    assert_match ">4<", response.body   # 3 order + 1 payout completed
    assert_match(/state=completed/, response.body)
    refute_match(/<html/, response.body) # rendered without the layout
  end

  test "in_flight frame counts idle + running" do
    get "/chrono_forge/overview/in_flight"
    assert_match(/<turbo-frame id="cf-ov-in-flight">/, response.body)
    assert_match ">2<", response.body   # ord-run (running) + pay-idle (idle)
    assert_match "state=in_flight", response.body
  end

  test "blocked frame counts failed + stalled and drills into the blocked filter" do
    get "/chrono_forge/overview/blocked"
    assert_match(/<turbo-frame id="cf-ov-blocked">/, response.body)
    assert_match ">1<", response.body
    assert_match "state=blocked", response.body
  end

  # --- table frame -----------------------------------------------------------

  test "classes frame renders a per-class row for each workflow class" do
    get "/chrono_forge/overview/classes"
    assert_response :success
    assert_match(/<turbo-frame id="cf-ov-classes">/, response.body)
    assert_match "OrderWorkflow", response.body
    assert_match "PayoutWorkflow", response.body
    assert_match "Totals", response.body
  end

  test "classes frame: processed count links into the completed list for that class" do
    get "/chrono_forge/overview/classes"
    assert_match(/job_class=OrderWorkflow&amp;state=completed/, response.body)
  end

  test "classes frame: blocked count is flagged and links to the blocked filter" do
    get "/chrono_forge/overview/classes"
    assert_match "state=blocked", response.body
    assert_match "⚠", response.body
  end

  test "classes frame: a class with no blocked work shows a quiet zero, not a link" do
    get "/chrono_forge/overview/classes"
    refute_match(/job_class=PayoutWorkflow&amp;state=blocked/, response.body)
  end

  test "classes frame: class name links into its per-class analytics" do
    get "/chrono_forge/overview/classes"
    assert_match(%r{analytics\?class=OrderWorkflow}, response.body)
  end

  test "classes frame: rows sort by processed, descending" do
    get "/chrono_forge/overview/classes"
    assert_operator response.body.index("OrderWorkflow"), :<, response.body.index("PayoutWorkflow")
  end

  test "classes frame: empty fleet shows an empty state" do
    ChronoForge::Workflow.delete_all
    get "/chrono_forge/overview/classes"
    assert_response :success
    assert_match "nothing has been processed", response.body
  end

  # --- nav -------------------------------------------------------------------

  test "nav exposes an Overview tab, with Workflows as the landing page" do
    get "/chrono_forge/overview"
    assert_match ">Overview<", response.body
    assert_match ">Workflows<", response.body
    # The landing/root route is the workflow list.
    get chrono_forge_dashboard.root_path
    assert_response :success
    assert_match ">Workflows</h1>", response.body
  end
end

class OverviewQueryTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  test "buckets counts into processed / in-flight / blocked per class" do
    2.times { |i| create_workflow(key: "d#{i}", state: :completed, job_class: "A") }
    create_workflow(key: "r", state: :running, job_class: "A")
    create_workflow(key: "i", state: :idle, job_class: "A")
    create_workflow(key: "f", state: :failed, job_class: "A")
    create_workflow(key: "s", state: :stalled, job_class: "A")

    row = ChronoForge::Dashboard::OverviewQuery.new.rows.find { |r| r.job_class == "A" }
    assert_equal 2, row.processed
    assert_equal 2, row.in_flight # running + idle
    assert_equal 2, row.blocked   # failed + stalled
    assert_equal 6, row.total
  end

  test "totals sum across classes" do
    create_workflow(key: "a", state: :completed, job_class: "A")
    create_workflow(key: "b", state: :completed, job_class: "B")
    create_workflow(key: "c", state: :failed, job_class: "B")

    totals = ChronoForge::Dashboard::OverviewQuery.new.totals
    assert_equal 2, totals.processed
    assert_equal 1, totals.blocked
    assert_nil totals.job_class
  end

  test "card total class methods count independently of the per-class rows" do
    2.times { |i| create_workflow(key: "c#{i}", state: :completed, job_class: "A") }
    create_workflow(key: "i", state: :idle, job_class: "B")
    create_workflow(key: "r", state: :running, job_class: "A")
    create_workflow(key: "f", state: :failed, job_class: "B")
    create_workflow(key: "s", state: :stalled, job_class: "A")

    assert_equal 2, ChronoForge::Dashboard::OverviewQuery.processed_total
    assert_equal 2, ChronoForge::Dashboard::OverviewQuery.in_flight_total # idle + running
    assert_equal 2, ChronoForge::Dashboard::OverviewQuery.blocked_total   # failed + stalled
  end
end
