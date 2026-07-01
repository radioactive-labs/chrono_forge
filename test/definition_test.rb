require "test_helper"

class DefinitionTest < ActiveSupport::TestCase
  def test_node_dynamic_predicate
    exact = ChronoForge::Definition::Node.new(id: "n1", kind: :execute, label: "charge", step_name: "durably_execute$charge")
    dyn   = ChronoForge::Definition::Node.new(id: "n2", kind: :dynamic, label: "?", step_name_pattern: "durably_execute$")
    refute exact.dynamic?
    assert dyn.dynamic?
  end

  def test_to_h_is_json_safe
    d = ChronoForge::Definition.new(
      nodes: [ChronoForge::Definition::Node.new(id: "n1", kind: :execute, label: "charge", step_name: "durably_execute$charge")],
      edges: [ChronoForge::Definition::Edge.new(from: "start", to: "n1", kind: :seq)],
      warnings: ["heads up"]
    )
    h = d.to_h
    assert_equal "durably_execute$charge", h[:nodes].first[:step_name]
    assert_equal :seq, h[:edges].first[:kind]
    assert_equal ["heads up"], h[:warnings]
    assert JSON.generate(h)
  end
end
