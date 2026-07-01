require "test_helper"

class DefinitionOverlayTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  def setup
    @wf = create_workflow(key: "ov", state: :running)
    @wf.execution_logs.create!(step_name: "durably_execute$charge",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
  end

  def defn
    ChronoForge::Definition.new(
      nodes: [
        ChronoForge::Definition::Node.new(id: "n1", kind: :execute, label: "charge", step_name: "durably_execute$charge"),
        ChronoForge::Definition::Node.new(id: "n2", kind: :execute, label: "ship", step_name: "durably_execute$ship")
      ],
      edges: [], warnings: []
    )
  end

  def test_marks_done_and_not_reached
    nodes = ChronoForge::Dashboard::DefinitionOverlay.new(defn, @wf).nodes
    by_id = nodes.index_by { |n| n[:id] }
    assert_equal :done, by_id["n1"][:status]
    assert_equal :not_reached, by_id["n2"][:status]
  end

  # A merge is a JOIN: its status comes from its OWN log, not child fan-out counts
  # (children are parented to the branch log, so a merge always has 0 children).
  def test_merge_status_from_own_log
    @wf.execution_logs.create!(step_name: "merge$a,b",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    d = ChronoForge::Definition.new(
      nodes: [ChronoForge::Definition::Node.new(id: "m1", kind: :merge, label: "merge a, b", step_name: "merge$a,b")],
      edges: [], warnings: []
    )
    nodes = ChronoForge::Dashboard::DefinitionOverlay.new(d, @wf).nodes
    assert_equal :done, nodes.find { |n| n[:id] == "m1" }[:status]
  end

  # A branch still aggregates status from its child-workflow counts.
  def test_branch_status_from_child_counts
    parent = @wf.execution_logs.create!(step_name: "branch$ship",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    create_workflow(key: "child-1", state: :completed, parent_execution_log_id: parent.id)
    d = ChronoForge::Definition.new(
      nodes: [ChronoForge::Definition::Node.new(id: "b1", kind: :branch, label: "branch ship", step_name: "branch$ship")],
      edges: [], warnings: []
    )
    node = ChronoForge::Dashboard::DefinitionOverlay.new(d, @wf).nodes.find { |n| n[:id] == "b1" }
    assert_equal :done, node[:status]
    assert node.key?(:counts)
  end

  def test_appends_unmapped_logs
    @wf.execution_logs.create!(step_name: "durably_execute$mystery",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    nodes = ChronoForge::Dashboard::DefinitionOverlay.new(defn, @wf).nodes
    unmapped = nodes.select { |n| n[:status] == :unmapped }
    assert_equal ["durably_execute$mystery"], unmapped.map { |n| n[:step_name] }
  end
end
