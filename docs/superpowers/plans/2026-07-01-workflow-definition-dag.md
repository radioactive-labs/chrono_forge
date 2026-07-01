# Workflow Definition DAG Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Statically parse a ChronoForge workflow's `perform` method with Prism to produce a conditional-DAG "definition" of the durable steps it will run, then render it on a new per-run dashboard page with the run's `execution_logs` overlaid as node status.

**Architecture:** A rendering-agnostic core analyzer (`ChronoForge::DefinitionAnalyzer`, Prism) emits value objects (`ChronoForge::Definition` / `Node` / `Edge`). The dashboard package overlays a run's logs (`DefinitionOverlay`, reusing `BranchProbe` for fan-out) and renders the statused graph to Mermaid flowchart text (`MermaidRenderer`) on a new `workflows/:id/definition` page. The analyzer only reads source text — never the DB, never executes workflow code.

**Tech Stack:** Ruby, Prism 1.x, ActiveRecord/ActiveJob, Minitest + Combustion (core), Rails engine + Tailwind + vendored Mermaid.js (dashboard).

**User Verification:** NO — no user verification required.

**Working directory:** worktree `.worktrees/workflow-definition-dag` (branch `feat/workflow-definition-dag`). Design spec: `docs/superpowers/specs/2026-07-01-workflow-definition-dag-design.md`.

**Step-name reference** (what the analyzer must reproduce, from `lib/chrono_forge/executor/methods/`):

| DSL | step name |
|---|---|
| `durably_execute :m` / `name:` | `durably_execute$#{name || m}` |
| `wait :n` | `wait$#{n}` |
| `wait_until :c` | `wait_until$#{c}` |
| `continue_if :c` / `name:` | `continue_if$#{name || c}` |
| `branch :n` | `branch$#{n}` |
| `merge_branches :a, :b` | `merge$#{[a,b].sort.join(",")}` |
| `durably_repeat :m` / `name:` | coord `durably_repeat$#{name || m}`; reps `durably_repeat$<name>$<ts>` |

---

### Task 1: `Definition` value objects + Prism dependency

**Goal:** The rendering-agnostic graph data model (`Definition`, `Node`, `Edge`) and the `prism` runtime dependency, with round-trippable `to_h`.

**Files:**
- Create: `lib/chrono_forge/definition.rb`
- Modify: `chrono_forge.gemspec` (add `prism`)
- Test: `test/definition_test.rb`

**Acceptance Criteria:**
- [ ] `ChronoForge::Definition` holds `nodes`, `edges`, `warnings`; `#to_h` returns plain JSON-safe hashes.
- [ ] `Node` exposes `id, kind, label, step_name, step_name_pattern, guard, warnings` and `#dynamic?`.
- [ ] `Edge` exposes `from, to, kind, guard`.
- [ ] `prism` is a declared runtime dependency (Ruby 3.2 doesn't bundle it).

**Verify:** `bundle exec ruby -I test test/definition_test.rb` → all green.

**Steps:**

- [ ] **Step 1: Add the Prism dependency** (`chrono_forge.gemspec`, after the `zeitwerk` line ~38)

```ruby
    spec.add_dependency "zeitwerk"
    spec.add_dependency "prism"
```

Then `bundle install` (updates the git-ignored `Gemfile.lock` already present in the worktree).

- [ ] **Step 2: Write the failing test** (`test/definition_test.rb`)

```ruby
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
    # Round-trips through JSON without custom coders.
    assert JSON.generate(h)
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `bundle exec ruby -I test test/definition_test.rb`
Expected: FAIL — `uninitialized constant ChronoForge::Definition`.

- [ ] **Step 4: Implement** (`lib/chrono_forge/definition.rb`)

```ruby
# frozen_string_literal: true

module ChronoForge
  # Rendering-agnostic graph model produced by DefinitionAnalyzer. Plain value
  # objects so a Definition can be cached/serialized (to_h -> JSON) and consumed
  # by any renderer. No DB, no Prism, no dashboard dependency here.
  class Definition
    # kind: :execute :wait :wait_until :continue_if :branch :merge :repeat :dynamic
    # A node binds to runtime logs by EXACT step_name when known, else by
    # step_name_pattern (a prefix for fan-out/repeat/dynamic).
    Node = Struct.new(
      :id, :kind, :label, :step_name, :step_name_pattern, :guard, :warnings,
      keyword_init: true
    ) do
      def warnings = super || []
      def dynamic? = kind == :dynamic || step_name.nil?
      def to_h = super.merge(warnings: warnings)
    end

    # kind: :seq :conditional :fanout :join :terminal
    Edge = Struct.new(:from, :to, :kind, :guard, keyword_init: true)

    attr_reader :nodes, :edges, :warnings

    def initialize(nodes: [], edges: [], warnings: [])
      @nodes = nodes
      @edges = edges
      @warnings = warnings
    end

    def to_h
      {nodes: nodes.map(&:to_h), edges: edges.map(&:to_h), warnings: warnings}
    end
  end
end
```

- [ ] **Step 5: Run to verify pass**

Run: `bundle exec ruby -I test test/definition_test.rb`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/chrono_forge/definition.rb test/definition_test.rb chrono_forge.gemspec Gemfile.lock
git commit -m "feat(definition): graph value objects + prism dependency"
```

---

### Task 2: Analyzer — linear steps

**Goal:** `DefinitionAnalyzer.call(workflow_class)` resolves the `perform` source via Prism and emits a node per straight-line durable call (`durably_execute`, `wait`, `wait_until`, `continue_if`, `merge_branches`) with sequential edges from a synthetic `start`.

**Files:**
- Create: `lib/chrono_forge/definition_analyzer.rb`
- Create: `test/support/definition_fixtures.rb` (fixture workflow classes)
- Test: `test/definition_analyzer_test.rb`

**Acceptance Criteria:**
- [ ] A linear workflow yields one node per durable call, in source order, each with the correct exact `step_name`.
- [ ] Edges chain `start → n1 → n2 → …` with `kind: :seq`.
- [ ] Non-durable Ruby (plain method calls, `context[...]=`) produces no nodes.
- [ ] No DB access, no workflow execution.

**Verify:** `bundle exec ruby -I test test/definition_analyzer_test.rb -n /linear/` → green.

**Steps:**

- [ ] **Step 1: Add the linear fixture** (`test/support/definition_fixtures.rb`)

```ruby
# Fixture workflow classes for DefinitionAnalyzer. Only their SOURCE is read
# (Prism); they are never executed, so the bodies can reference helpers freely.
module DefinitionFixtures
  class Linear
    def perform
      context["started"] = true
      durably_execute :charge_card
      wait_until :funds_cleared
      wait :cooloff
      continue_if :approved
      durably_execute :ship, name: "ship_it"
      merge_branches :b, :a
    end
  end
end
```

- [ ] **Step 2: Write the failing test** (`test/definition_analyzer_test.rb`)

```ruby
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
    # Every consecutive pair is connected by a :seq edge.
    ids.each_cons(2) do |a, b|
      assert d.edges.any? { |e| e.from == a && e.to == b && e.kind == :seq }
    end
  end

  def test_ignores_non_durable_ruby
    d = defn(DefinitionFixtures::Linear)
    refute d.nodes.any? { |n| n.label.include?("context") }
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `bundle exec ruby -I test test/definition_analyzer_test.rb -n /linear/`
Expected: FAIL — `uninitialized constant ChronoForge::DefinitionAnalyzer`.

- [ ] **Step 4: Implement the analyzer core + linear visitor** (`lib/chrono_forge/definition_analyzer.rb`)

```ruby
# frozen_string_literal: true

require "prism"

module ChronoForge
  # Statically analyzes a workflow class's `perform` method (via Prism) into a
  # conservative Definition graph. Reads SOURCE TEXT ONLY — never the DB, never
  # executes workflow code. Unresolvable Ruby becomes a :dynamic node + warning.
  class DefinitionAnalyzer
    # The durable DSL calls we recognize -> node kind.
    DURABLE = {
      durably_execute: :execute, wait: :wait, wait_until: :wait_until,
      continue_if: :continue_if, branch: :branch, merge_branches: :merge,
      merge_branch: :merge, durably_repeat: :repeat
    }.freeze

    def self.call(workflow_class) = new(workflow_class).call

    def initialize(workflow_class)
      @klass = workflow_class
      @nodes = []
      @edges = []
      @warnings = []
      @seq = 0
    end

    def call
      file, method_node, defs = locate_perform
      return unavailable unless method_node

      @defs = defs # name(Symbol) => Prism::DefNode, for same-class helper tracing
      last = "start"
      last = walk(method_node.body, last)
      Definition.new(nodes: @nodes, edges: @edges, warnings: @warnings)
    rescue => e
      unavailable("analysis error: #{e.class}: #{e.message}")
    end

    private

    # Resolve perform's source file, parse it, and collect every instance-method
    # DefNode in the same class body (for helper tracing).
    def locate_perform
      loc = @klass.instance_method(:perform).source_location
      return [nil, nil, {}] unless loc && File.readable?(loc.first)

      result = Prism.parse_file(loc.first)
      defs = {}
      perform = nil
      collect = ->(node) do
        return unless node.is_a?(Prism::DefNode)
        defs[node.name] = node
        perform = node if node.name == :perform
      end
      each_def(result.value, &collect)
      [loc.first, perform, defs]
    end

    # Yield every DefNode anywhere under `node` (workflows may nest in modules).
    def each_def(node, &blk)
      return unless node.is_a?(Prism::Node)
      blk.call(node)
      node.compact_child_nodes.each { |c| each_def(c, &blk) }
    end

    # Walk a body node in source order, threading the "previous node id" so we can
    # emit sequential edges. Returns the id of the last node reached (the exit).
    def walk(node, prev)
      return prev if node.nil?

      statements =
        case node
        when Prism::StatementsNode then node.body
        else [node]
        end

      statements.each { |stmt| prev = visit(stmt, prev) }
      prev
    end

    # Visit one statement; return the new "previous" id (unchanged if it emitted
    # nothing). Task 2 handles only durable call statements + descends into plain
    # calls' blocks are added later.
    def visit(stmt, prev)
      if (call = durable_call(stmt))
        return emit_durable(call, prev)
      end
      prev
    end

    # A Prism::CallNode whose method is a recognized durable DSL call with no
    # explicit receiver (or `self`). Returns the CallNode or nil.
    def durable_call(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless DURABLE.key?(node.name)
      return nil unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
      node
    end

    def emit_durable(call, prev)
      kind = DURABLE.fetch(call.name)
      name, dynamic = resolved_name(call)
      step_name = dynamic ? nil : step_name_for(call.name, name, call)
      node = add_node(
        kind: dynamic ? :dynamic : kind,
        label: label_for(call.name, name),
        step_name: step_name,
        step_name_pattern: ("#{prefix_for(call.name)}$" if dynamic),
        warnings: (dynamic ? ["#{call.name}: dynamic name — bound by prefix/ordinal"] : [])
      )
      add_edge(prev, node.id, :seq)
      node.id
    end

    # First positional arg as a literal Symbol/String, honoring a literal `name:`
    # keyword override. Returns [name_string_or_nil, dynamic?].
    def resolved_name(call)
      override = keyword_literal(call, :name)
      return [override, false] if override

      first = positional_args(call).first
      lit = literal_value(first)
      lit ? [lit, false] : [nil, true]
    end

    def step_name_for(dsl, name, call)
      case dsl
      when :merge_branches, :merge_branch
        names = positional_args(call).map { |a| literal_value(a) }
        return nil if names.any?(&:nil?)
        "merge$#{names.sort.join(",")}"
      else
        "#{prefix_for(dsl)}$#{name}"
      end
    end

    def prefix_for(dsl)
      case dsl
      when :merge_branches, :merge_branch then "merge"
      when :branch then "branch"
      when :durably_repeat then "durably_repeat"
      else dsl.to_s
      end
    end

    def label_for(dsl, name) = name ? "#{dsl} #{name}" : dsl.to_s

    # ---- Prism literal helpers ----

    def positional_args(call)
      (call.arguments&.arguments || []).reject { |a| a.is_a?(Prism::KeywordHashNode) }
    end

    def keyword_literal(call, key)
      hash = (call.arguments&.arguments || []).find { |a| a.is_a?(Prism::KeywordHashNode) }
      return nil unless hash
      assoc = hash.elements.grep(Prism::AssocNode).find do |e|
        e.key.is_a?(Prism::SymbolNode) && e.key.value.to_sym == key
      end
      assoc && literal_value(assoc.value)
    end

    def literal_value(node)
      case node
      when Prism::SymbolNode then node.value
      when Prism::StringNode then node.unescaped
      end
    end

    # ---- graph builders ----

    def add_node(**attrs)
      node = Definition::Node.new(id: "n#{@seq += 1}", **attrs)
      @nodes << node
      node
    end

    def add_edge(from, to, kind, guard = nil)
      @edges << Definition::Edge.new(from: from, to: to, kind: kind, guard: guard)
    end

    def unavailable(msg = "perform source is not statically analyzable")
      Definition.new(nodes: [], edges: [], warnings: [msg])
    end
  end
end
```

- [ ] **Step 5: Run to verify pass**

Run: `bundle exec ruby -I test test/definition_analyzer_test.rb -n /linear/`
Expected: PASS (linear tests). Then run the whole file — the ignore test passes too.

- [ ] **Step 6: Commit**

```bash
git add lib/chrono_forge/definition_analyzer.rb test/definition_analyzer_test.rb test/support/definition_fixtures.rb
git commit -m "feat(analyzer): linear durable-step extraction via Prism"
```

---

### Task 3: Analyzer — conditionals & guards

**Goal:** Model `if`/`unless`/`case` around durable calls as `:conditional` edges carrying a guard label; a step reachable only inside a conditional is marked `conditional`; `continue_if`'s false path becomes a `:terminal` edge.

**Files:**
- Modify: `lib/chrono_forge/definition_analyzer.rb` (`visit`)
- Modify: `test/support/definition_fixtures.rb` (add `Conditional`)
- Test: `test/definition_analyzer_test.rb`

**Acceptance Criteria:**
- [ ] A durable call inside `if cond` yields a node reached by a `:conditional` edge whose `guard` is the condition source (e.g., `"vip?"`).
- [ ] Statements after the `if` rejoin: the post-`if` node has edges from BOTH the conditional body's exit and the pre-`if` node (skip path).
- [ ] `continue_if` emits a `:terminal` edge to a synthetic `halt` sink (false path halts the workflow).

**Verify:** `bundle exec ruby -I test test/definition_analyzer_test.rb -n /conditional|guard|continue_if/` → green.

**Steps:**

- [ ] **Step 1: Add the fixture** (`test/support/definition_fixtures.rb`, inside the module)

```ruby
  class Conditional
    def perform
      durably_execute :charge
      if vip?
        durably_execute :gift
      end
      continue_if :approved
      durably_execute :ship
    end
  end
```

- [ ] **Step 2: Write the failing tests** (`test/definition_analyzer_test.rb`)

```ruby
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
    # continue_if is reachable from the gift body AND directly from charge (skip).
    assert d.edges.any? { |e| e.from == gift.id && e.to == approved.id }
    assert d.edges.any? { |e| e.from == charge.id && e.to == approved.id }
  end

  def test_continue_if_has_terminal_false_path
    d = defn(DefinitionFixtures::Conditional)
    approved = d.nodes.find { |n| n.step_name == "continue_if$approved" }
    assert d.edges.any? { |e| e.from == approved.id && e.kind == :terminal }
  end
```

- [ ] **Step 3: Run to verify failure**

Run: `bundle exec ruby -I test test/definition_analyzer_test.rb -n /conditional|continue_if/`
Expected: FAIL — conditional bodies aren't walked yet (no `gift` node), no terminal edge.

- [ ] **Step 4: Extend `visit`** (`lib/chrono_forge/definition_analyzer.rb`) — replace the `visit` method with:

```ruby
    def visit(stmt, prev)
      case stmt
      when Prism::IfNode, Prism::UnlessNode
        return visit_conditional(stmt, prev)
      when Prism::CaseNode
        return visit_case(stmt, prev)
      else
        if (call = durable_call(stmt))
          id = emit_durable(call, prev)
          id = attach_terminal(call, id) if call.name == :continue_if
          return id
        end
      end
      prev
    end

    # if/unless: walk the body under a guard, then rejoin with the skip path so
    # the next statement is reachable both ways. Returns a synthetic join id.
    def visit_conditional(node, prev)
      guard = source_of(node.predicate)
      body = node.is_a?(Prism::UnlessNode) ? node.statements : node.statements
      # Re-point the FIRST durable edge emitted in the body as :conditional(guard).
      before = @edges.size
      body_exit = walk(body, prev)
      mark_first_edge_conditional(before, prev, guard)

      # else branch (if present) also flows from prev.
      else_exit = prev
      if node.respond_to?(:subsequent) && (sub = node.subsequent)
        before_else = @edges.size
        else_exit = walk(sub.is_a?(Prism::ElseNode) ? sub.statements : sub, prev)
        mark_first_edge_conditional(before_else, prev, "!(#{guard})") if else_exit != prev
      end

      join = add_node(kind: :join, label: "join", step_name: nil)
      add_edge(body_exit, join.id, :seq)
      add_edge(prev, join.id, :seq) if body_exit != prev && else_exit == prev # skip path
      add_edge(else_exit, join.id, :seq) if else_exit != prev
      join.id
    end

    def visit_case(node, prev)
      exits = []
      node.conditions.each do |when_node|
        guard = when_node.conditions.map { |c| source_of(c) }.join(", ")
        before = @edges.size
        exit_id = walk(when_node.statements, prev)
        mark_first_edge_conditional(before, prev, guard)
        exits << exit_id
      end
      exits << walk(node.else_clause&.statements, prev) if node.else_clause
      join = add_node(kind: :join, label: "join", step_name: nil)
      (exits.uniq - [prev]).each { |e| add_edge(e, join.id, :seq) }
      add_edge(prev, join.id, :seq) # fall-through/no-match path
      join.id
    end

    # The first edge added at/after `before` that starts at `prev` is the entry
    # into the conditional body; relabel it :conditional with the guard.
    def mark_first_edge_conditional(before, prev, guard)
      edge = @edges[before..].find { |e| e.from == prev }
      return unless edge
      edge.kind = :conditional
      edge.guard = guard
    end

    def attach_terminal(_call, id)
      sink = (@halt ||= add_node(kind: :dynamic, label: "halt", step_name: nil))
      add_edge(id, sink.id, :terminal, "condition false")
      id
    end

    # Best-effort source text of a predicate node (for guard labels). Falls back
    # to the node type when slicing isn't available.
    def source_of(node)
      node.respond_to?(:slice) ? node.slice : node.class.name.split("::").last
    end
```

Note: `Prism::Node#slice` returns the exact source substring — ideal for guard labels.

- [ ] **Step 5: Run to verify pass**

Run: `bundle exec ruby -I test test/definition_analyzer_test.rb`
Expected: PASS (linear + conditional). If a `:join` node interferes with the linear `each_cons` edge test, confirm linear has no conditionals so no join nodes are added there.

- [ ] **Step 6: Commit**

```bash
git add lib/chrono_forge/definition_analyzer.rb test/definition_analyzer_test.rb test/support/definition_fixtures.rb
git commit -m "feat(analyzer): guarded conditional edges and continue_if terminal"
```

---

### Task 4: Analyzer — branch fan-out + merge join

**Goal:** A `branch name do … end` block becomes a `:branch` fan-out node; its `spawn`/`spawn_each` calls become a child-group node reached by a `:fanout` edge; a following `merge_branches` node is reached by a `:join` edge.

**Files:**
- Modify: `lib/chrono_forge/definition_analyzer.rb` (`visit` block handling)
- Modify: `test/support/definition_fixtures.rb` (add `FanOut`)
- Test: `test/definition_analyzer_test.rb`

**Acceptance Criteria:**
- [ ] `branch :ship do spawn_each(:pkg, …) end` yields a `:branch` node (`step_name "branch$ship"`) plus a child-group node with `step_name_pattern` for the spawn.
- [ ] The branch node → child-group edge is `:fanout`.
- [ ] A later `merge_branches :ship` node is connected from the branch by a `:join` edge.

**Verify:** `bundle exec ruby -I test test/definition_analyzer_test.rb -n /fanout|branch|merge/` → green.

**Steps:**

- [ ] **Step 1: Add the fixture** (`test/support/definition_fixtures.rb`)

```ruby
  class FanOut
    def perform
      branch :ship do
        spawn_each :pkg, orders
      end
      merge_branches :ship
    end
  end
```

- [ ] **Step 2: Write the failing tests** (`test/definition_analyzer_test.rb`)

```ruby
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
```

- [ ] **Step 3: Run to verify failure**

Run: `bundle exec ruby -I test test/definition_analyzer_test.rb -n /fanout|merge_joins/`
Expected: FAIL — branch block body isn't walked; no child-group node; merge not joined.

- [ ] **Step 4: Handle branch blocks + merge join** (`lib/chrono_forge/definition_analyzer.rb`)

In `emit_durable`, after creating the node, special-case `:branch` to walk its block for spawns and remember it for the join. Add to the top of `emit_durable` (after `node =` is created and the `:seq` edge added, replace the `node.id` return) with:

```ruby
      add_edge(prev, node.id, :seq)

      if call.name == :branch && call.block
        emit_branch_children(call.block, node)
        @branches ||= {}
        @branches[name] = node.id
      end
      if kind == :merge
        positional_args(call).each do |a|
          bname = literal_value(a)
          src = @branches && @branches[bname]
          add_edge(src, node.id, :join) if src
        end
      end
      node.id
    end

    # A branch's spawn/spawn_each calls become one child-group node per call,
    # reached by a :fanout edge. Children are keyed <wf.key>$<branch>$<name>_* at
    # runtime, so we bind by that prefix pattern (best effort — the overlay uses
    # BranchProbe counts, not the pattern, for fan-out status).
    def emit_branch_children(block, branch_node)
      body = block.is_a?(Prism::BlockNode) ? block.body : nil
      stmts = body.is_a?(Prism::StatementsNode) ? body.body : Array(body)
      stmts.each do |stmt|
        next unless stmt.is_a?(Prism::CallNode) && %i[spawn spawn_each].include?(stmt.name)
        sname = literal_value(positional_args(stmt).first)
        child = add_node(
          kind: :dynamic,
          label: "#{stmt.name} #{sname}".strip,
          step_name: nil,
          step_name_pattern: (sname ? "spawn:#{sname}" : "spawn"),
          warnings: ["fan-out — status is aggregated from child workflows"]
        )
        add_edge(branch_node.id, child.id, :fanout)
      end
    end
```

Note: this requires `@branches` to be reset per `call` — it's an instance var initialized lazily and the analyzer instance is per-workflow, so it's fine. `emit_durable`'s existing `add_edge(prev, node.id, :seq)` line is now inside this block; delete the old duplicate at the end.

- [ ] **Step 5: Run to verify pass**

Run: `bundle exec ruby -I test test/definition_analyzer_test.rb`
Expected: PASS (all prior + fan-out).

- [ ] **Step 6: Commit**

```bash
git add lib/chrono_forge/definition_analyzer.rb test/definition_analyzer_test.rb test/support/definition_fixtures.rb
git commit -m "feat(analyzer): branch fan-out nodes and merge join edges"
```

---

### Task 5: Analyzer — repeat loop, same-class helper tracing, warnings

**Goal:** `durably_repeat` becomes a `:repeat` node; durable calls factored into same-class helper methods are traced inline (fixed point, recursion-guarded); a durable call inside an `each`/`times`/`while` loop or behind an unknown call emits a warning.

**Files:**
- Modify: `lib/chrono_forge/definition_analyzer.rb`
- Modify: `test/support/definition_fixtures.rb` (add `Repeat`, `Traced`, `Loopy`)
- Test: `test/definition_analyzer_test.rb`

**Acceptance Criteria:**
- [ ] `durably_repeat :tick` → one `:repeat` node, `step_name "durably_repeat$tick"`.
- [ ] A `perform` that calls a same-class helper containing `durably_execute` produces that step's node (traced), in position.
- [ ] A durable call inside `orders.each { durably_execute … }` produces a warning on the Definition and does not crash.
- [ ] Recursive/mutually-recursive helpers don't loop forever.

**Verify:** `bundle exec ruby -I test test/definition_analyzer_test.rb -n /repeat|traced|loop|helper/` → green.

**Steps:**

- [ ] **Step 1: Add fixtures** (`test/support/definition_fixtures.rb`)

```ruby
  class Repeat
    def perform
      durably_repeat :tick, every: 1.second, till: :done?
    end
  end

  class Traced
    def perform
      setup
      durably_execute :finish
    end

    private

    def setup
      durably_execute :charge
    end
  end

  class Loopy
    def perform
      orders.each { |o| durably_execute :ship }
    end
  end
```

- [ ] **Step 2: Write the failing tests** (`test/definition_analyzer_test.rb`)

```ruby
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
```

- [ ] **Step 3: Run to verify failure**

Run: `bundle exec ruby -I test test/definition_analyzer_test.rb -n /repeat|traced|loop/`
Expected: FAIL — helper not traced (only `finish`), no loop warning.

- [ ] **Step 4: Add helper tracing + loop warnings** (`lib/chrono_forge/definition_analyzer.rb`)

Extend `visit`'s `else` branch: when a bare call matches a same-class def, recurse into it; when it's an iteration node, warn. Replace the `else` clause body in `visit` with:

```ruby
      else
        if (call = durable_call(stmt))
          id = emit_durable(call, prev)
          id = attach_terminal(call, id) if call.name == :continue_if
          return id
        elsif (helper = traceable_helper(stmt))
          return trace_helper(helper, prev)
        elsif loop_with_durable?(stmt)
          @warnings << "durable step inside a loop (#{stmt.class.name.split("::").last}) — " \
            "count is data-dependent; shown once, not unrolled"
          return walk_loop_body(stmt, prev)
        end
      end
```

Add these helpers:

```ruby
    # A bare (receiverless) call to a method defined on the same class whose body
    # contains a durable call — worth tracing inline. Guards against recursion.
    def traceable_helper(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
      dfn = @defs[node.name]
      return nil unless dfn
      return nil if (@tracing ||= []).include?(node.name)
      body_has_durable?(dfn.body) ? dfn : nil
    end

    def trace_helper(dfn, prev)
      (@tracing ||= []) << dfn.name
      result = walk(dfn.body, prev)
      @tracing.pop
      result
    end

    def body_has_durable?(node)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(Prism::CallNode) && DURABLE.key?(node.name) &&
        (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
      node.compact_child_nodes.any? { |c| body_has_durable?(c) }
    end

    def loop_with_durable?(node)
      case node
      when Prism::WhileNode, Prism::UntilNode, Prism::ForNode
        body_has_durable?(node)
      when Prism::CallNode
        %i[each times upto downto each_with_index map].include?(node.name) &&
          node.block && body_has_durable?(node.block)
      else
        false
      end
    end

    # Walk a loop body ONCE so the contained steps appear (with the warning), not
    # unrolled. Handles both keyword loops and iterator blocks.
    def walk_loop_body(node, prev)
      body =
        case node
        when Prism::CallNode then node.block.is_a?(Prism::BlockNode) ? node.block.body : nil
        else node.respond_to?(:statements) ? node.statements : nil
        end
      walk(body, prev)
    end
```

- [ ] **Step 5: Run to verify pass**

Run: `bundle exec ruby -I test test/definition_analyzer_test.rb`
Expected: PASS (all analyzer tests, including a full run over every fixture).

- [ ] **Step 6: Commit**

```bash
git add lib/chrono_forge/definition_analyzer.rb test/definition_analyzer_test.rb test/support/definition_fixtures.rb
git commit -m "feat(analyzer): repeat node, same-class helper tracing, loop warnings"
```

---

### Task 6: Dashboard — `DefinitionOverlay`

**Goal:** Given a `Definition` + a workflow, annotate each node with a runtime `status` from `execution_logs` (exact-name lookup), fan-out/repeat aggregates (via `BranchProbe` / repetition logs), and append `unmapped` nodes for logs with no matching static node.

**Files:**
- Create: `chrono_forge-dashboard/app/presenters/chrono_forge/dashboard/definition_overlay.rb`
- Test: `chrono_forge-dashboard/test/definition_overlay_test.rb`

**Acceptance Criteria:**
- [ ] Exact-name node → `status` ∈ `{done, active, failed, stalled, not_reached}` from its log.
- [ ] `:branch`/`:merge` node → `status` + `counts` (running/idle/completed/failed) from child workflows.
- [ ] `:repeat` node → `repetitions` count from `durably_repeat$<name>$*` logs.
- [ ] A completed log with no matching node appends an `unmapped` node.

**Verify:** `cd chrono_forge-dashboard && bundle exec rake test TEST=test/definition_overlay_test.rb` → green. (Copy the git-ignored working `Gemfile.lock` into the worktree's `chrono_forge-dashboard/` first — already done during worktree setup; see [[worktree-gemfile-lock]].)

**Steps:**

- [ ] **Step 1: Write the failing test** (`chrono_forge-dashboard/test/definition_overlay_test.rb`)

```ruby
require "test_helper"

class DefinitionOverlayTest < ActiveSupport::TestCase
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
```

(If `create_workflow` isn't a shared helper, mirror the factory used in `test/branches_test.rb`.)

- [ ] **Step 2: Run to verify failure**

Run: `cd chrono_forge-dashboard && bundle exec rake test TEST=test/definition_overlay_test.rb`
Expected: FAIL — `uninitialized constant ChronoForge::Dashboard::DefinitionOverlay`.

- [ ] **Step 3: Implement** (`chrono_forge-dashboard/app/presenters/chrono_forge/dashboard/definition_overlay.rb`)

```ruby
module ChronoForge
  module Dashboard
    # Overlays a workflow run's execution_logs onto a static Definition, producing
    # per-node hashes with a runtime :status (and fan-out/repeat aggregates).
    # Read-only. The Definition is the static map; logs are the source of truth
    # for a specific run.
    class DefinitionOverlay
      LOG_STATUS = {"completed" => :done, "running" => :active,
                    "failed" => :failed, "stalled" => :stalled}.freeze

      def initialize(definition, workflow)
        @definition = definition
        @workflow = workflow
      end

      def nodes
        mapped = @definition.nodes.map { |n| overlay(n) }
        mapped + unmapped_nodes(mapped)
      end

      def warnings = @definition.warnings

      private

      def overlay(node)
        base = node.to_h.merge(status: :not_reached)
        case node.kind
        when :branch, :merge then base.merge(fanout_status(node))
        when :repeat then base.merge(repeat_status(node))
        else
          log = logs_by_name[node.step_name]
          log ? base.merge(status: LOG_STATUS.fetch(log_state(log), :active)) : base
        end
      end

      def fanout_status(node)
        log = logs_by_name[node.step_name]
        return {status: :not_reached} unless log
        counts = ChronoForge::Workflow
          .where(parent_execution_log_id: log.id)
          .group(:state).count
          .transform_keys { |k| ChronoForge::Workflow.states.key(k) || k }
        status = if counts["failed"].to_i.positive? then :failed
        elsif counts.except("completed").values.sum.positive? then :active
        elsif counts.any? then :done
        else :not_reached
        end
        {status: status, counts: counts}
      end

      def repeat_status(node)
        coord = logs_by_name[node.step_name]
        return {status: :not_reached} unless coord
        reps = @workflow.execution_logs
          .where("step_name LIKE ?", "#{node.step_name}$%").count
        {status: (coord_done?(coord) ? :done : :active), repetitions: reps}
      end

      def unmapped_nodes(mapped)
        known = mapped.filter_map { |n| n[:step_name] }.to_set
        @workflow.execution_logs
          .reject { |l| known.include?(l.step_name) || framework_log?(l) }
          .map do |l|
            {id: "log-#{l.id}", kind: :dynamic, label: l.step_name, step_name: l.step_name,
             status: :unmapped, warnings: ["no matching static node"]}
          end
      end

      # Skip framework-internal and fan-out child/rep logs (they're aggregated).
      def framework_log?(log)
        log.step_name.start_with?("$") ||
          log.step_name.count("$") >= 2 # durably_repeat$name$ts, etc.
      end

      def logs_by_name
        @logs_by_name ||= @workflow.execution_logs.index_by(&:step_name)
      end

      def log_state(log) = ChronoForge::ExecutionLog.states.key(log.state) || log.state.to_s
      def coord_done?(log) = log_state(log) == "completed"
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `cd chrono_forge-dashboard && bundle exec rake test TEST=test/definition_overlay_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add chrono_forge-dashboard/app/presenters/chrono_forge/dashboard/definition_overlay.rb chrono_forge-dashboard/test/definition_overlay_test.rb
git commit -m "feat(dashboard): overlay execution_logs onto the definition graph"
```

---

### Task 7: Dashboard — `MermaidRenderer`

**Goal:** Turn statused overlay nodes + Definition edges into a Mermaid `flowchart TD` string, with status encoded via `classDef`/`class`.

**Files:**
- Create: `chrono_forge-dashboard/app/presenters/chrono_forge/dashboard/mermaid_renderer.rb`
- Test: `chrono_forge-dashboard/test/mermaid_renderer_test.rb`

**Acceptance Criteria:**
- [ ] Emits `flowchart TD`, one line per node with a shape by kind and a `:::status` class.
- [ ] Emits one edge line per Definition edge; conditional/terminal edges carry their guard as an edge label.
- [ ] Includes `classDef` lines for every status used.

**Verify:** `cd chrono_forge-dashboard && bundle exec rake test TEST=test/mermaid_renderer_test.rb` → green.

**Steps:**

- [ ] **Step 1: Write the failing test** (`chrono_forge-dashboard/test/mermaid_renderer_test.rb`)

```ruby
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd chrono_forge-dashboard && bundle exec rake test TEST=test/mermaid_renderer_test.rb`
Expected: FAIL — constant missing.

- [ ] **Step 3: Implement** (`chrono_forge-dashboard/app/presenters/chrono_forge/dashboard/mermaid_renderer.rb`)

```ruby
module ChronoForge
  module Dashboard
    # Renders statused overlay nodes + Definition edges to Mermaid flowchart text.
    # Rendering-only: no DB, no analysis.
    class MermaidRenderer
      SHAPES = {
        execute: ->(l) { "[\"#{l}\"]" }, wait: ->(l) { "([\"#{l}\"])" },
        wait_until: ->(l) { "{{\"#{l}\"}}" }, continue_if: ->(l) { "{\"#{l}\"}" },
        branch: ->(l) { "[/\"#{l}\"/]" }, merge: ->(l) { "[\\\"#{l}\\\"]" },
        repeat: ->(l) { "[[\"#{l}\"]]" }, join: ->(_) { "((\" \"))" },
        dynamic: ->(l) { "[\"#{l}\"]" }
      }.freeze

      CLASS_DEFS = {
        done: "fill:#16a34a22,stroke:#16a34a", active: "fill:#2563eb22,stroke:#2563eb",
        pending: "fill:#a1a1aa22,stroke:#a1a1aa", not_reached: "fill:#fff,stroke:#d4d4d8",
        failed: "fill:#dc262622,stroke:#dc2626", stalled: "fill:#d9770622,stroke:#d97706",
        unmapped: "fill:#f5f5f4,stroke:#a8a29e,stroke-dasharray:3 3"
      }.freeze

      def initialize(nodes, edges)
        @nodes = nodes
        @edges = edges
      end

      def to_mermaid
        lines = ["flowchart TD"]
        @nodes.each { |n| lines << "  #{n[:id]}#{shape(n)}:::#{n[:status]}" }
        @edges.each { |e| lines << "  #{edge(e)}" }
        used_statuses.each { |s| lines << "  classDef #{s} #{CLASS_DEFS[s]}" }
        lines.join("\n")
      end

      private

      def shape(node)
        label = sanitize(node[:label].to_s)
        (SHAPES[node[:kind]] || SHAPES[:dynamic]).call(label)
      end

      def edge(e)
        guard = e.guard && !e.guard.empty? ? "|#{sanitize(e.guard)}| " : ""
        arrow = e.kind == :terminal ? "-.->" : "-->"
        "#{e.from} #{arrow}#{guard.empty? ? " " : " #{guard}"}#{e.to}".squeeze(" ")
      end

      def used_statuses = @nodes.map { |n| n[:status] }.uniq.select { |s| CLASS_DEFS.key?(s) }
      def sanitize(s) = s.gsub('"', "'").gsub(/[\[\]{}|]/, " ").strip
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `cd chrono_forge-dashboard && bundle exec rake test TEST=test/mermaid_renderer_test.rb`
Expected: PASS. (If the edge-label assertion is whitespace-sensitive, adjust `edge` spacing to match `n1 -->|vip?| n2` exactly.)

- [ ] **Step 5: Commit**

```bash
git add chrono_forge-dashboard/app/presenters/chrono_forge/dashboard/mermaid_renderer.rb chrono_forge-dashboard/test/mermaid_renderer_test.rb
git commit -m "feat(dashboard): render statused definition graph to Mermaid"
```

---

### Task 8: Dashboard — definition page (route, controller, view, Mermaid, link)

**Goal:** A new `GET workflows/:id/definition` page that analyzes the workflow's class, overlays the run, renders the Mermaid graph client-side (vendored), lists warnings, and is linked from the workflow detail page.

**Files:**
- Modify: `chrono_forge-dashboard/config/routes.rb`
- Create: `chrono_forge-dashboard/app/controllers/chrono_forge/dashboard/definitions_controller.rb`
- Create: `chrono_forge-dashboard/app/views/chrono_forge/dashboard/definitions/show.html.erb`
- Create: `chrono_forge-dashboard/app/assets/chrono_forge/dashboard/mermaid.min.js` (vendored Mermaid UMD build)
- Modify: `chrono_forge-dashboard/app/views/chrono_forge/dashboard/workflows/show.html.erb` (add link)
- Modify: `chrono_forge-dashboard/config/routes.rb` assets constraint (serve mermaid.js)
- Test: `chrono_forge-dashboard/test/definitions_controller_test.rb`

**Acceptance Criteria:**
- [ ] `GET workflows/:id/definition` returns 200 and includes a `flowchart TD` payload for an analyzable workflow.
- [ ] An unanalyzable/unknown class renders the page with a warning, not a 500.
- [ ] The workflow detail page links to the new page.

**Verify:** `cd chrono_forge-dashboard && bundle exec rake test TEST=test/definitions_controller_test.rb` → green.

**Steps:**

- [ ] **Step 1: Write the failing controller test** (`chrono_forge-dashboard/test/definitions_controller_test.rb`)

```ruby
require "test_helper"

class DefinitionsControllerTest < ActionDispatch::IntegrationTest
  include ChronoForge::Dashboard::Engine.routes.url_helpers
  def setup
    @wf = create_workflow(key: "def-page", state: :running, job_class: "DefinitionFixtures::Linear")
  end

  def test_show_renders_a_flowchart
    get definition_workflow_path(@wf)
    assert_response :success
    assert_match(/flowchart TD/, @response.body)
  end

  def test_unknown_class_degrades_gracefully
    @wf.update!(job_class: "Nope::DoesNotExist")
    get definition_workflow_path(@wf)
    assert_response :success
    assert_match(/statically analyz/i, @response.body)
  end
end
```

Ensure `DefinitionFixtures::Linear` is loadable from the dashboard test env (add `require` in the dashboard `test_helper.rb`, or define a small analyzable workflow class in the dashboard test support).

- [ ] **Step 2: Run to verify failure**

Run: `cd chrono_forge-dashboard && bundle exec rake test TEST=test/definitions_controller_test.rb`
Expected: FAIL — no route/controller.

- [ ] **Step 3: Add the route** (`chrono_forge-dashboard/config/routes.rb`) — add inside the `resources :workflows` member block, and extend the assets constraint:

```ruby
    member do
      post :retry, to: "actions#retry"
      post :resume, to: "actions#resume"
      post :unlock, to: "actions#unlock"
      get :repetitions, to: "repetitions#index"
      get :definition, to: "definitions#show"
    end
```

and change the assets line to also serve `mermaid.min.js`:

```ruby
  get "assets/:file", to: "assets#show", constraints: {file: /(dashboard\.(css|js)|mermaid\.min\.js)/}
```

(Confirm `AssetsController#show` maps the filename to `app/assets/chrono_forge/dashboard/#{file}`; extend its allowlist if it hardcodes names.)

- [ ] **Step 4: Add the controller** (`chrono_forge-dashboard/app/controllers/chrono_forge/dashboard/definitions_controller.rb`)

```ruby
module ChronoForge
  module Dashboard
    class DefinitionsController < BaseController
      def show
        @workflow = ChronoForge::Workflow.find(params[:id])
        definition = analyze(@workflow)
        overlay = DefinitionOverlay.new(definition, @workflow)
        @nodes = overlay.nodes
        @warnings = overlay.warnings
        @mermaid = MermaidRenderer.new(@nodes, definition.edges).to_mermaid
      end

      private

      # Never let analysis break the page: an unknown/unloadable class or an
      # unanalyzable body yields an empty definition with a warning.
      def analyze(workflow)
        klass = workflow.job_class.constantize
        ChronoForge::DefinitionAnalyzer.call(klass) ||
          ChronoForge::Definition.new(warnings: ["perform source is not statically analyzable"])
      rescue NameError
        ChronoForge::Definition.new(warnings: ["workflow class #{workflow.job_class} is not loadable"])
      end
    end
  end
end
```

- [ ] **Step 5: Add the view** (`chrono_forge-dashboard/app/views/chrono_forge/dashboard/definitions/show.html.erb`)

```erb
<%= link_to "‹ Back to workflow", workflow_path(@workflow), class: cf_chip("mb-2") %>

<div class="mb-4">
  <h1 class="text-lg font-semibold text-zinc-800">Definition graph</h1>
  <p class="text-xs text-zinc-500"><%= @workflow.job_class %> — <%= @workflow.key %></p>
</div>

<% if @warnings.any? %>
  <div class="mb-4 rounded border border-amber-300 bg-amber-50 p-3 text-xs text-amber-800">
    <p class="font-medium mb-1">Static analysis notes</p>
    <ul class="list-disc pl-4 space-y-0.5">
      <% @warnings.each do |w| %><li><%= w %></li><% end %>
    </ul>
  </div>
<% end %>

<div class="rounded border border-zinc-200 bg-white p-4 overflow-auto">
  <pre class="mermaid"><%= @mermaid %></pre>
</div>

<script src="<%= dashboard_asset_path("mermaid.min.js") %>"></script>
<script>
  (function () {
    if (window.mermaid) { window.mermaid.initialize({ startOnLoad: true }); window.mermaid.run(); }
  })();
</script>
```

Use whatever asset-path helper the dashboard already exposes for `dashboard.js`/`dashboard.css` (grep the layout `application.html.erb`); if it's a bare route, replace `dashboard_asset_path("mermaid.min.js")` with `assets_path(file: "mermaid.min.js")` or the engine's equivalent. `cf_chip` is the existing chip helper used in `workflows/show.html.erb`.

- [ ] **Step 6: Vendor Mermaid** — download a pinned Mermaid UMD build to `chrono_forge-dashboard/app/assets/chrono_forge/dashboard/mermaid.min.js`:

```bash
curl -fsSL https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js \
  -o chrono_forge-dashboard/app/assets/chrono_forge/dashboard/mermaid.min.js
test -s chrono_forge-dashboard/app/assets/chrono_forge/dashboard/mermaid.min.js && echo "vendored"
```

- [ ] **Step 7: Link from the workflow detail page** (`chrono_forge-dashboard/app/views/chrono_forge/dashboard/workflows/show.html.erb`) — add near the existing action links/header (match surrounding markup):

```erb
<%= link_to "Definition graph", definition_workflow_path(@workflow), class: cf_chip("mb-2") %>
```

- [ ] **Step 8: Run the page test + full dashboard suite**

Run: `cd chrono_forge-dashboard && bundle exec rake test TEST=test/definitions_controller_test.rb`
Then: `cd chrono_forge-dashboard && bundle exec rake test`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add chrono_forge-dashboard/config/routes.rb \
  chrono_forge-dashboard/app/controllers/chrono_forge/dashboard/definitions_controller.rb \
  chrono_forge-dashboard/app/views/chrono_forge/dashboard/definitions/show.html.erb \
  chrono_forge-dashboard/app/views/chrono_forge/dashboard/workflows/show.html.erb \
  chrono_forge-dashboard/app/assets/chrono_forge/dashboard/mermaid.min.js \
  chrono_forge-dashboard/test/definitions_controller_test.rb
git commit -m "feat(dashboard): per-run workflow definition DAG page with Mermaid"
```

---

### Task 9: Full suite + docs

**Goal:** Confirm the whole feature is green across both packages and note the feature in the scale/dashboard docs.

**Files:**
- Modify: `chrono_forge-dashboard/README.md` (or the dashboard docs) — one paragraph on the definition page.

**Acceptance Criteria:**
- [ ] Core suite green: `bundle exec rake test`.
- [ ] Dashboard suite green: `cd chrono_forge-dashboard && bundle exec rake test`.
- [ ] `bundle exec standardrb` (or the repo's linter) clean on new files.

**Verify:** both suites green; lint clean.

**Steps:**

- [ ] **Step 1: Run both suites**

```bash
bundle exec rake test
cd chrono_forge-dashboard && bundle exec rake test && cd ..
```
Expected: all PASS.

- [ ] **Step 2: Lint new files**

Run: `bundle exec standardrb lib/chrono_forge/definition.rb lib/chrono_forge/definition_analyzer.rb`
Fix any offenses.

- [ ] **Step 3: Document the page** (`chrono_forge-dashboard/README.md`) — add a short "Definition graph" paragraph describing the per-run static DAG + overlay.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs: note the workflow definition DAG page; final lint pass"
```

---

## Self-Review

**Spec coverage:** Analyzer core + all 7 primitives → Tasks 2–5 (linear; conditionals/continue_if; branch/merge fan-out; repeat/helper-tracing/loop-warnings). Value objects → Task 1. Overlay + status vocabulary + fan-out/repeat aggregates + unmapped → Task 6. Mermaid rendering → Task 7. New per-run page + route + link + vendored Mermaid + graceful degradation → Task 8. Caching is an optimization noted in the spec; the controller analyzes per request (memoization by class+digest is a trivial follow-up, deliberately deferred to avoid premature caching — noted here as the one spec item intentionally not wired in v1). Testing → each task is TDD; full-suite gate → Task 9.

**Placeholder scan:** No TBD/TODO. Two steps say "use the existing helper (grep X)" for the asset-path helper and `create_workflow` factory — these reference concrete existing dashboard conventions the implementer must match rather than invent; acceptable (they name the exact thing to find).

**Type consistency:** `DefinitionAnalyzer.call → Definition`; `Definition#nodes/#edges/#warnings`; `Node#to_h` used by the overlay; overlay returns **hashes** (with `:status`) and `MermaidRenderer.new(nodes_hashes, edges)` consumes hashes for nodes + `Edge` structs for edges — consistent between Tasks 6 and 7. Step-name strings match the DSL table. `DURABLE` keys match method names.

**Verification requirement scan:** The prompt ("explore… parsing a workflow for the future timeline", "Do it") requests NO user verification, confirmation, or human sign-off of outcomes. Answer: **NO.** No `requiresUserVerification` task needed.

**Deferred (per spec):** cross-class tracing; recursive child-workflow expansion; per-node ETA; class-level no-overlay view; Definition memoization.
