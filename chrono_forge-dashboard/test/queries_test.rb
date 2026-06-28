require "test_helper"

class QueriesTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  setup do
    create_workflow(key: "a", state: :failed, job_class: "OrderWorkflow")
    create_workflow(key: "b", state: :completed, job_class: "OrderWorkflow")
    create_workflow(key: "c", state: :failed, job_class: "PayoutWorkflow")
  end

  test "filters by state" do
    q = ChronoForge::Dashboard::WorkflowsQuery.new(state: "failed")
    assert_equal %w[a c].sort, q.records.map(&:key).sort
  end

  test "filters by job_class and key prefix" do
    assert_equal ["a"], ChronoForge::Dashboard::WorkflowsQuery.new(job_class: "OrderWorkflow", key: "a").records.map(&:key)
  end

  test "key filter is a prefix match, not a substring match" do
    create_workflow(key: "order-99", state: :idle)
    assert_equal ["order-99"], ChronoForge::Dashboard::WorkflowsQuery.new(key: "order").records.map(&:key)
    assert_empty ChronoForge::Dashboard::WorkflowsQuery.new(key: "rder").records
  end

  test "blank filters return all, newest id first" do
    q = ChronoForge::Dashboard::WorkflowsQuery.new(state: "", job_class: nil)
    assert_equal %w[c b a], q.records.map(&:key)
  end

  test "keyset paginates without offset or count" do
    page1 = ChronoForge::Dashboard::WorkflowsQuery.new(per: 2)
    assert_equal %w[c b], page1.records.map(&:key)
    assert page1.has_next?
    refute page1.has_prev?

    page2 = ChronoForge::Dashboard::WorkflowsQuery.new(per: 2, before: page1.next_cursor)
    assert_equal %w[a], page2.records.map(&:key)
    refute page2.has_next?
    assert page2.has_prev?

    back = ChronoForge::Dashboard::WorkflowsQuery.new(per: 2, after: page2.prev_cursor)
    assert_equal %w[c b], back.records.map(&:key)
  end

  test "runs over a custom base scope" do
    q = ChronoForge::Dashboard::WorkflowsQuery.new(base: ChronoForge::Workflow.where(job_class: "PayoutWorkflow"))
    assert_equal ["c"], q.records.map(&:key)
  end

  test "includes branch children by default (branch-children view depends on it)" do
    spawn_branch_child(key: "child")
    assert_includes ChronoForge::Dashboard::WorkflowsQuery.new.records.map(&:key), "child"
  end

  test "exclude_branched drops spawned branch children, keeps top-level" do
    spawn_branch_child(key: "child")
    keys = ChronoForge::Dashboard::WorkflowsQuery.new(exclude_branched: true).records.map(&:key)
    refute_includes keys, "child"
    assert_equal %w[a b c].sort, keys.sort
  end

  test "stats exclude branch children when based on the top-level scope" do
    spawn_branch_child(key: "child", state: :failed)
    top_level = ChronoForge::Workflow.where(parent_execution_log_id: nil)
    counts = ChronoForge::Dashboard::StatsQuery.new(base: top_level).counts
    assert_equal 2, counts["failed"], "a and c only — the spawned failed child is excluded"
  end

  # A workflow spawned inside a branch: linked to a branch$ coordination log via
  # parent_execution_log_id (what distinguishes it from a top-level workflow).
  def spawn_branch_child(key:, state: :idle)
    parent = ChronoForge::Workflow.find_by!(key: "a") # an existing top-level workflow
    branch_log = parent.execution_logs.create!(
      step_name: "branch$g", state: ChronoForge::ExecutionLog.states[:completed]
    )
    create_workflow(key: key, state: state, parent_execution_log_id: branch_log.id)
  end

  test "stats counts every state" do
    counts = ChronoForge::Dashboard::StatsQuery.new.counts
    assert_equal 2, counts["failed"]
    assert_equal 1, counts["completed"]
    assert_equal 0, counts["running"]
  end

  test "stats counts are capped" do
    counts = ChronoForge::Dashboard::StatsQuery.new(cap: 1).counts
    assert_equal 1, counts["failed"], "2 failed workflows, capped to 1"
  end
end
