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
    assert_includes out, "n1 -->|vip?| n2"
    assert_match(/classDef done /, out)
  end
end
