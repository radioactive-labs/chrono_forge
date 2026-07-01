require "test_helper"
require "support/definition_fixtures"

class DefinitionAnalyzerTest < ActiveSupport::TestCase
  def defn(klass) = ChronoForge::DefinitionAnalyzer.call(klass)

  def test_linear_emits_a_node_per_durable_call_in_order
    d = defn(DefinitionFixtures::Linear)
    assert_equal(
      %w[durably_execute$charge_card wait_until$funds_cleared wait$cooloff
         continue_if$approved durably_execute$ship_it merge$a,b],
      d.nodes.map(&:step_name)
    )
    assert_equal %i[execute wait_until wait continue_if execute merge], d.nodes.map(&:kind)
  end

  def test_linear_chains_sequential_edges_from_start
    d = defn(DefinitionFixtures::Linear)
    ids = d.nodes.map(&:id)
    assert_equal "start", d.edges.first.from
    assert_equal ids.first, d.edges.first.to
    ids.each_cons(2) do |a, b|
      assert d.edges.any? { |e| e.from == a && e.to == b && e.kind == :seq }
    end
  end

  def test_ignores_non_durable_ruby
    d = defn(DefinitionFixtures::Linear)
    refute d.nodes.any? { |n| n.label.include?("context") }
  end

  def test_conditional_body_reached_by_guarded_edge
    d = defn(DefinitionFixtures::Conditional)
    gift = d.nodes.find { |n| n.step_name == "durably_execute$gift" }
    edge = d.edges.find { |e| e.to == gift.id }
    assert_equal :conditional, edge.kind
    assert_equal "vip?", edge.guard
  end

  def test_conditional_rejoins_skip_and_body_paths
    d = defn(DefinitionFixtures::Conditional)
    charge = d.nodes.find { |n| n.step_name == "durably_execute$charge" }
    gift   = d.nodes.find { |n| n.step_name == "durably_execute$gift" }
    approved = d.nodes.find { |n| n.step_name == "continue_if$approved" }
    assert d.edges.any? { |e| e.from == gift.id && e.to == approved.id }
    assert d.edges.any? { |e| e.from == charge.id && e.to == approved.id }
  end

  def test_continue_if_has_terminal_false_path
    d = defn(DefinitionFixtures::Conditional)
    approved = d.nodes.find { |n| n.step_name == "continue_if$approved" }
    assert d.edges.any? { |e| e.from == approved.id && e.kind == :terminal }
  end
end
