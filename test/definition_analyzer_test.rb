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

  def test_early_returns_emit_guarded_terminal_edges_to_halt
    d = defn(DefinitionFixtures::EarlyReturn)
    terminals = d.edges.select { |e| e.to == "halt" && e.kind == :terminal }
    # `return unless ready?` and `if done? then return` — two exits.
    assert_equal ["!(ready?)", "done?"].sort, terminals.map(&:guard).sort
    # The main flow still threads through both durable steps.
    steps = d.nodes.select { |n| n.kind == :execute }
    assert_equal %w[durably_execute$step_one durably_execute$step_two], steps.map(&:step_name)
    one, two = steps.map(&:id)
    assert d.edges.any? { |e| e.from == "start" && e.to == one && e.kind == :seq }
    assert d.edges.any? { |e| e.from == one && e.to == two && e.kind == :seq }
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
    gift = d.nodes.find { |n| n.step_name == "durably_execute$gift" }
    approved = d.nodes.find { |n| n.step_name == "continue_if$approved" }
    assert d.edges.any? { |e| e.from == gift.id && e.to == approved.id }
    assert d.edges.any? { |e| e.from == charge.id && e.to == approved.id }
  end

  def test_continue_if_has_terminal_false_path
    d = defn(DefinitionFixtures::Conditional)
    approved = d.nodes.find { |n| n.step_name == "continue_if$approved" }
    assert d.edges.any? { |e| e.from == approved.id && e.kind == :terminal }
  end

  def test_branch_emits_fanout_node_and_child_group
    d = defn(DefinitionFixtures::FanOut)
    br = d.nodes.find { |n| n.step_name == "branch$ship" }
    assert_equal :branch, br.kind
    child = d.nodes.find { |n| n.kind == :dynamic && n.label.include?("spawn_each") }
    assert child, "expected a child-group node for spawn_each"
    assert d.edges.any? { |e| e.from == br.id && e.to == child.id && e.kind == :fanout }
  end

  def test_merge_joins_the_branch
    d = defn(DefinitionFixtures::FanOut)
    br = d.nodes.find { |n| n.step_name == "branch$ship" }
    mg = d.nodes.find { |n| n.step_name == "merge$ship" }
    assert d.edges.any? { |e| e.from == br.id && e.to == mg.id && e.kind == :join }
  end

  def test_repeat_is_a_single_repeat_node
    d = defn(DefinitionFixtures::Repeat)
    rep = d.nodes.find { |n| n.kind == :repeat }
    assert_equal "durably_repeat$tick", rep.step_name
  end

  def test_traces_durable_calls_in_same_class_helpers
    d = defn(DefinitionFixtures::Traced)
    assert_equal %w[durably_execute$charge durably_execute$finish], d.nodes.map(&:step_name)
  end

  def test_durable_call_inside_loop_warns
    d = defn(DefinitionFixtures::Loopy)
    assert d.warnings.any? { |w| w.match?(/loop/i) }
  end

  # C1: unless inverts the guards.
  def test_unless_guards_are_inverted
    d = defn(DefinitionFixtures::Unless)
    a = d.nodes.find { |n| n.step_name == "durably_execute$a" }
    b = d.nodes.find { |n| n.step_name == "durably_execute$b" }
    assert_equal "!(vip?)", d.edges.find { |e| e.to == a.id }.guard
    assert_equal "vip?", d.edges.find { |e| e.to == b.id }.guard
  end

  # C2: nested if composes the outer guard with the inner.
  def test_nested_if_composes_guards
    d = defn(DefinitionFixtures::Nested)
    a = d.nodes.find { |n| n.step_name == "durably_execute$a" }
    assert_equal "x? && y?", d.edges.find { |e| e.to == a.id }.guard
  end

  # C2: elsif/else compose negated outer predicates.
  def test_elsif_composes_negated_guards
    d = defn(DefinitionFixtures::Elsif)
    a = d.nodes.find { |n| n.step_name == "durably_execute$a" }
    c = d.nodes.find { |n| n.step_name == "durably_execute$c" }
    dd = d.nodes.find { |n| n.step_name == "durably_execute$d" }
    assert_equal "x?", d.edges.find { |e| e.to == a.id }.guard
    assert_equal "!(x?) && y?", d.edges.find { |e| e.to == c.id }.guard
    assert_equal "!(x?) && !(y?)", d.edges.find { |e| e.to == dd.id }.guard
  end

  # C3: same-named helper resolves within each class, not last-parsed.
  def test_same_named_helper_traces_own_class
    assert_equal %w[durably_execute$first_impl],
      defn(DefinitionFixtures::FirstWf).nodes.map(&:step_name)
    assert_equal %w[durably_execute$second_impl],
      defn(DefinitionFixtures::SecondWf).nodes.map(&:step_name)
  end

  # I1: dynamic branch + dynamic merge must not fabricate a join.
  def test_dynamic_merge_does_not_fabricate_join
    d = defn(DefinitionFixtures::DynMerge)
    refute d.edges.any? { |e| e.kind == :join }
  end

  # I3: merge label lists all literal branch names.
  def test_merge_label_lists_all_branch_names
    d = defn(DefinitionFixtures::Linear)
    mg = d.nodes.find { |n| n.step_name == "merge$a,b" }
    assert_includes mg.label, "a"
    assert_includes mg.label, "b"
  end

  # M3: multiline predicate collapses to a single-line guard.
  def test_multiline_guard_is_single_line
    d = defn(DefinitionFixtures::Multiline)
    m = d.nodes.find { |n| n.step_name == "durably_execute$m" }
    guard = d.edges.find { |e| e.to == m.id }.guard
    refute_includes guard, "\n"
    assert_equal "(a? && b?)", guard
  end

  # Real DSL arg positions: wait's name is 2nd positional; name: kw overrides.
  def test_names_resolve_per_real_dsl_arg_positions
    d = defn(DefinitionFixtures::Waits)
    assert_equal(
      %w[wait$cool_down wait$until_deadline durably_execute$settle
        continue_if$gate durably_repeat$ticker],
      d.nodes.map(&:step_name)
    )
    assert_equal %i[wait wait execute continue_if repeat], d.nodes.map(&:kind)
    refute d.nodes.any?(&:dynamic?)
  end

  # A truly non-literal name stays dynamic with a prefix-only pattern.
  def test_non_literal_name_is_dynamic
    d = defn(DefinitionFixtures::DynExec)
    node = d.nodes.first
    assert_equal :dynamic, node.kind
    assert_nil node.step_name
    assert_equal "durably_execute$", node.step_name_pattern
  end

  # I2: durable calls inside begin/rescue are not dropped.
  def test_begin_rescue_bodies_are_walked
    names = defn(DefinitionFixtures::Begins).nodes.map(&:step_name)
    assert_includes names, "durably_execute$risky"
    assert_includes names, "durably_execute$fallback"
  end

  # Durable calls on the RHS of an assignment (local/ivar/multi-assign) still emit.
  def test_assigned_durable_calls_are_not_dropped
    names = defn(DefinitionFixtures::Assigned).nodes.map(&:step_name)
    assert_equal %w[durably_execute$charge wait_until$funds_cleared durably_execute$ship], names
  end

  # Durable operands of && / || still emit.
  def test_boolean_operand_durable_calls_are_not_dropped
    names = defn(DefinitionFixtures::Boolean).nodes.map(&:step_name)
    assert_equal %w[durably_execute$notify wait_until$warm], names
  end

  # case/in (CaseMatchNode) branch bodies are walked; patterns become guards.
  def test_case_in_branches_are_walked
    d = defn(DefinitionFixtures::CaseIn)
    ship = d.nodes.find { |n| n.step_name == "durably_execute$ship" }
    unblock = d.nodes.find { |n| n.step_name == "continue_if$unblocked" }
    assert ship, "expected the :ready branch step"
    assert unblock, "expected the :blocked branch step"
    assert_equal ":ready", d.edges.find { |e| e.to == ship.id }.guard
  end

  # A perform with no durable calls yields zero nodes plus an explanatory warning,
  # so the graph page shows a readable empty state instead of nothing.
  def test_empty_perform_warns_with_no_nodes
    d = defn(DefinitionFixtures::Empty)
    assert_empty d.nodes
    assert d.warnings.any? { |w| w.match?(/no durable steps/i) }
  end

  # merge_branches with a non-literal name among literals is dynamic, not a merge
  # node with a nil step_name that silently never binds.
  def test_mixed_merge_names_are_dynamic_not_nil_merge
    node = defn(DefinitionFixtures::MixedMerge).nodes.find { |n| n.label.include?("merge") }
    assert node, "expected a merge node"
    assert_equal :dynamic, node.kind
    assert_nil node.step_name
    assert node.warnings.any? { |w| w.match?(/dynamic/i) }
  end
end
