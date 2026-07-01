require "test_helper"

class CytoscapeGraphTest < ActiveSupport::TestCase
  def test_builds_node_and_edge_elements_with_status_and_kind_classes
    nodes = [
      {id: "n1", kind: :execute, label: "charge", step_name: "durably_execute$charge", status: :done},
      {id: "n2", kind: :wait, label: "hold", step_name: "wait$hold", status: :not_reached}
    ]
    edges = [ChronoForge::Definition::Edge.new(from: "n1", to: "n2", kind: :seq, guard: nil)]
    g = ChronoForge::Dashboard::CytoscapeGraph.new(nodes, edges).to_h

    n1 = g[:nodes].find { |n| n[:data][:id] == "n1" }
    assert_equal "charge", n1[:data][:label]
    assert_equal "durably_execute$charge", n1[:data][:step_name]
    assert_equal "kind-execute status-done", n1[:classes]

    assert_equal [{data: {id: "e0", source: "n1", target: "n2", label: ""}, classes: "kind-seq"}], g[:edges]
  end

  # Guards with ( ) and < are just JSON strings here — no escaping, no grammar.
  def test_guard_text_is_verbatim_in_edge_data
    nodes = [{id: "n1", kind: :wait, label: "w", step_name: nil, status: :not_reached}]
    edges = [ChronoForge::Definition::Edge.new(
      from: "start", to: "n1", kind: :conditional, guard: "a? && !(b < c)"
    )]
    g = ChronoForge::Dashboard::CytoscapeGraph.new(nodes, edges).to_h
    assert_equal "a? && !(b < c)", g[:edges].first[:data][:label]
  end

  # start/halt are edge endpoints with no node; synthesize them so Cytoscape can
  # attach the edges.
  def test_synthesizes_virtual_endpoint_nodes
    nodes = [{id: "n1", kind: :continue_if, label: "gate", step_name: "continue_if$gate", status: :done}]
    edges = [
      ChronoForge::Definition::Edge.new(from: "start", to: "n1", kind: :seq, guard: nil),
      ChronoForge::Definition::Edge.new(from: "n1", to: "halt", kind: :terminal, guard: "condition false")
    ]
    g = ChronoForge::Dashboard::CytoscapeGraph.new(nodes, edges).to_h
    ids = g[:nodes].map { |n| n[:data][:id] }
    assert_includes ids, "start"
    assert_includes ids, "halt"
    assert_equal "kind-endpoint", g[:nodes].find { |n| n[:data][:id] == "start" }[:classes]
  end
end
