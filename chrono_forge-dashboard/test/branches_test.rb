require "test_helper"

class BranchesPresenterTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  def branch_log(wf, name, state: :completed)
    wf.execution_logs.create!(step_name: "branch$#{name}",
      state: ChronoForge::ExecutionLog.states[state], attempts: 1, started_at: 1.hour.ago)
  end

  def child(branch_log, key, state)
    create_workflow(key: key, state: state, job_class: "OrderWorkflow", parent_execution_log_id: branch_log.id)
  end

  test "summarizes a branch with capped dispatched/pending/blocked counts" do
    parent = create_workflow(key: "p1", state: :idle)
    bl = branch_log(parent, "fulfillment")
    child(bl, "p1$fulfillment$1", :completed)
    child(bl, "p1$fulfillment$2", :failed)
    child(bl, "p1$fulfillment$3", :stalled)
    child(bl, "p1$fulfillment$4", :running)

    presenter = ChronoForge::Dashboard::BranchesPresenter.new(parent)
    assert presenter.any?
    b = presenter.branches.first
    assert_equal "fulfillment", b.name
    assert b.sealed?
    assert_equal 4, b.dispatched
    assert_equal 3, b.pending  # everything not completed
    assert_equal 2, b.blocked  # failed + stalled
  end

  test "poll_overdue? flags a dropped BranchMergeJob poller" do
    parent = create_workflow(key: "pp", state: :idle)
    overdue = parent.execution_logs.create!(step_name: "branch$a",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 2.hours.ago,
      metadata: {"poll" => {"next_poll_at" => 1.hour.ago.iso8601, "last_polled_at" => 65.minutes.ago.iso8601, "polls" => 9}})
    healthy = parent.execution_logs.create!(step_name: "branch$b",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 2.hours.ago,
      metadata: {"poll" => {"next_poll_at" => 5.minutes.from_now.iso8601, "polls" => 3}})

    assert ChronoForge::Dashboard::BranchPresenter.new(overdue).poll_overdue?
    refute ChronoForge::Dashboard::BranchPresenter.new(healthy).poll_overdue?
    # A completed merge clears next_poll_at, so it never looks overdue.
    done = parent.execution_logs.create!(step_name: "branch$c",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 2.hours.ago,
      metadata: {"poll" => {"next_poll_at" => nil, "polls" => 12}})
    refute ChronoForge::Dashboard::BranchPresenter.new(done).poll_overdue?
  end

  test "merge log marks a branch merging (pending) or merged (completed)" do
    parent = create_workflow(key: "pm", state: :idle)
    branch_log(parent, "invoicing")
    parent.execution_logs.create!(step_name: "merge$invoicing",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1, started_at: 1.hour.ago)

    assert_equal :merging, ChronoForge::Dashboard::BranchesPresenter.new(parent).branches.first.merge_state
  end

  test "no branches for a plain workflow" do
    refute ChronoForge::Dashboard::BranchesPresenter.new(create_workflow(key: "plain")).any?
  end

  test "lists merge joins, in-progress first" do
    parent = create_workflow(key: "pj", state: :idle)
    branch_log(parent, "a")
    branch_log(parent, "b")
    parent.execution_logs.create!(step_name: "merge$a", state: ChronoForge::ExecutionLog.states[:completed],
      attempts: 1, started_at: 2.hours.ago)
    parent.execution_logs.create!(step_name: "merge$b", state: ChronoForge::ExecutionLog.states[:pending],
      attempts: 1, started_at: 1.hour.ago)

    merges = ChronoForge::Dashboard::BranchesPresenter.new(parent).merges
    assert_equal 2, merges.size
    assert merges.first.merging?           # pending sorts first
    assert_equal ["b"], merges.first.names
    assert_equal :merged, merges.last.state
  end

  test "exposes live throughput/ETA on an in-flight merge" do
    parent = create_workflow(key: "pt", state: :idle)
    parent.execution_logs.create!(step_name: "branch$g",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.hour.ago,
      metadata: {"poll" => {"rate" => 226.0, "pending" => 19_888, "eta_seconds" => 88,
                            "last_polled_at" => 20.seconds.ago.iso8601, "polls" => 3}})
    parent.execution_logs.create!(step_name: "merge$g", state: ChronoForge::ExecutionLog.states[:pending],
      attempts: 1, started_at: 1.hour.ago)

    merge = ChronoForge::Dashboard::BranchesPresenter.new(parent).merges.first
    assert_equal 226.0, merge.rate
    assert_equal 88, merge.eta_seconds # 19,888 pending ÷ 226/s (single-branch: aggregate == the one branch)
    assert merge.throughput?, "a merging, draining merge reports throughput"
  end

  test "throughput? is false when the merge isn't draining or is already merged" do
    parent = create_workflow(key: "pt0", state: :idle)
    parent.execution_logs.create!(step_name: "branch$idle",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.hour.ago,
      metadata: {"poll" => {"rate" => 0.0, "eta_seconds" => nil, "polls" => 5}})
    parent.execution_logs.create!(step_name: "merge$idle", state: ChronoForge::ExecutionLog.states[:pending],
      attempts: 1, started_at: 1.hour.ago)
    parent.execution_logs.create!(step_name: "branch$done",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.hour.ago,
      metadata: {"poll" => {"rate" => 500.0, "polls" => 7}})
    parent.execution_logs.create!(step_name: "merge$done", state: ChronoForge::ExecutionLog.states[:completed],
      attempts: 1, started_at: 1.hour.ago)

    merges = ChronoForge::Dashboard::BranchesPresenter.new(parent).merges.index_by { |m| m.names.first }
    refute merges["idle"].throughput?, "rate 0.0 is not draining"
    refute merges["done"].throughput?, "a merged join isn't a live gauge"
  end

  # A merge may join several branches; each records its OWN rate/pending, so the
  # merge's throughput is the sum and its ETA the combined remaining over the
  # combined rate — not any single branch's figure.
  test "aggregates rate/ETA across a multi-branch merge" do
    parent = create_workflow(key: "p-multi", state: :idle)
    parent.execution_logs.create!(step_name: "branch$a",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.hour.ago,
      metadata: {"poll" => {"rate" => 100.0, "pending" => 600,
                            "last_polled_at" => 10.seconds.ago.iso8601, "polls" => 4}})
    parent.execution_logs.create!(step_name: "branch$b",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.hour.ago,
      metadata: {"poll" => {"rate" => 100.0, "pending" => 900,
                            "last_polled_at" => 10.seconds.ago.iso8601, "polls" => 4}})
    parent.execution_logs.create!(step_name: "merge$a,b", state: ChronoForge::ExecutionLog.states[:pending],
      attempts: 1, started_at: 30.seconds.ago)

    merge = ChronoForge::Dashboard::BranchesPresenter.new(parent).merges.first
    assert_equal ["a", "b"], merge.names
    assert_in_delta 200.0, merge.rate, 0.001, "rate is the sum of both branches (100 + 100)"
    assert_equal 8, merge.eta_seconds, "ETA is combined pending (1500) over combined rate (200) = 7.5 → 8"
    assert merge.throughput?
  end
end

class BranchChildrenControllerTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers
  include ActiveJob::TestHelper

  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  def setup_branch
    parent = create_workflow(key: "pc", state: :idle)
    bl = parent.execution_logs.create!(step_name: "branch$orders",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.hour.ago)
    create_workflow(key: "pc-orders-ok", state: :completed, job_class: "OrderWorkflow", parent_execution_log_id: bl.id)
    create_workflow(key: "pc-orders-bad", state: :failed, job_class: "OrderWorkflow", parent_execution_log_id: bl.id)
    [parent, bl]
  end

  test "defaults to the blocked children" do
    parent, bl = setup_branch
    get "/chrono_forge/workflows/#{parent.id}/branches/#{bl.id}"
    assert_response :success
    assert_match "pc-orders-bad", response.body
    refute_match "pc-orders-ok", response.body
  end

  test "state=all shows every child" do
    parent, bl = setup_branch
    get "/chrono_forge/workflows/#{parent.id}/branches/#{bl.id}", params: {state: ""}
    assert_match "pc-orders-bad", response.body
    assert_match "pc-orders-ok", response.body
  end

  test "filter chips render a colored state dot for each real state" do
    parent, bl = setup_branch
    get "/chrono_forge/workflows/#{parent.id}/branches/#{bl.id}", params: {state: ""}
    assert_match "cf-dot-running", response.body
    assert_match "cf-dot-completed", response.body
    assert_match "cf-dot-failed", response.body
  end

  test "bulk retry re-enqueues blocked children only" do
    parent, bl = setup_branch
    assert_enqueued_jobs 1 do
      post "/chrono_forge/workflows/#{parent.id}/branches/#{bl.id}/bulk_retry"
    end
  end

  test "child detail shows the parent breadcrumb" do
    setup_branch
    child = ChronoForge::Workflow.find_by(key: "pc-orders-bad")
    get "/chrono_forge/workflows/#{child.id}"
    assert_response :success
    assert_match "pc", response.body
    assert_match "branch orders", response.body
  end
end
