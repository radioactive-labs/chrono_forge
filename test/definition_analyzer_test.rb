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
end
