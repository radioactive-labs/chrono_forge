require "test_helper"

class MermaidRendererTest < ActiveSupport::TestCase
  def test_renders_nodes_edges_and_classes
    nodes = [
      {id: "n1", kind: :execute, label: "charge", status: :done},
      {id: "n2", kind: :wait_until, label: "funds?", status: :active}
    ]
    edges = [ChronoForge::Definition::Edge.new(from: "n1", to: "n2", kind: :conditional, guard: "vip?")]
    out = ChronoForge::Dashboard::MermaidRenderer.new(nodes, edges).to_mermaid

    assert_match(/\Aflowchart TD/, out)
    assert_includes out, 'n1["charge"]:::done'
    assert_includes out, 'n1 -->|"vip?"| n2'
    assert_match(/classDef done /, out)
  end

  # Guards from negated/compared predicates contain ( ) and <, which Mermaid
  # rejects in a bare |label|. They must be emitted inside quotes so the graph
  # still parses (regression: real workflows like ScheduledPaymentRecurrence).
  def test_guard_with_parens_and_angle_brackets_is_quoted
    nodes = [{id: "n1", kind: :wait, label: "hold", status: :not_reached}]
    edges = [ChronoForge::Definition::Edge.new(
      from: "start", to: "n1", kind: :conditional,
      guard: "auto_charge? && !(reminder < charge_time)"
    )]
    out = ChronoForge::Dashboard::MermaidRenderer.new(nodes, edges).to_mermaid

    assert_includes out, %(start -->|"auto_charge? && !(reminder < charge_time)"| n1)
  end
end
