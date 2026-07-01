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

  def test_appends_unmapped_logs
    @wf.execution_logs.create!(step_name: "durably_execute$mystery",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    nodes = ChronoForge::Dashboard::DefinitionOverlay.new(defn, @wf).nodes
    unmapped = nodes.select { |n| n[:status] == :unmapped }
    assert_equal ["durably_execute$mystery"], unmapped.map { |n| n[:step_name] }
  end
end
