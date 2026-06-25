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
    assert_equal %w[a c].sort, q.results.map(&:key).sort
  end

  test "filters by job_class and key substring" do
    assert_equal ["a"], ChronoForge::Dashboard::WorkflowsQuery.new(job_class: "OrderWorkflow", key: "a").results.map(&:key)
  end

  test "blank filters return all" do
    assert_equal 3, ChronoForge::Dashboard::WorkflowsQuery.new(state: "", job_class: nil).results.count
  end

  test "paginates" do
    q = ChronoForge::Dashboard::WorkflowsQuery.new(page: 1, per: 2)
    assert_equal 2, q.results.to_a.size
    assert_equal 3, q.total_count
  end

  test "stats counts every state" do
    counts = ChronoForge::Dashboard::StatsQuery.new.counts
    assert_equal 2, counts["failed"]
    assert_equal 1, counts["completed"]
    assert_equal 0, counts["running"]
  end
end
