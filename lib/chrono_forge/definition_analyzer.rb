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

      file, line = loc
      result = Prism.parse_file(file)
      defs = {}
      perform = nil
      collect = ->(node) do
        return unless node.is_a?(Prism::DefNode)
        defs[node.name] = node
        # A file may hold several workflow classes (each with its own #perform);
        # bind to the one whose `def` starts on this method's source line.
        perform = node if node.name == :perform && node.location.start_line == line
      end
      each_def(result.value, &collect)
      [file, perform, defs]
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
    # nothing). `prev` may be a single node id or a list of ids (the multiple
    # exits of a conditional that rejoin at the next statement).
    def visit(stmt, prev)
      case stmt
      when Prism::IfNode, Prism::UnlessNode
        visit_conditional(stmt, prev)
      when Prism::CaseNode
        visit_case(stmt, prev)
      else
        if (call = durable_call(stmt))
          id = emit_durable(call, prev)
          id = attach_terminal(call, id) if call.name == :continue_if
          id
        else
          prev
        end
      end
    end

    # if/unless: walk the body under a guard, then expose BOTH the body exit(s)
    # and the skip path (pre-`if` node, or the else-branch exits) so the next
    # statement is reachable every way. Returns a list of exit ids.
    def visit_conditional(node, prev)
      guard = source_of(node.predicate)
      before = @edges.size
      body_exit = walk(node.statements, prev)
      mark_entry_conditional(before, prev, guard)

      exits = to_list(body_exit)
      if (sub = branch_else(node))
        before_else = @edges.size
        else_stmts = sub.is_a?(Prism::ElseNode) ? sub.statements : sub
        else_exit = walk(else_stmts, prev)
        mark_entry_conditional(before_else, prev, negate(guard))
        exits |= to_list(else_exit)
      else
        exits |= to_list(prev) # no else: skip path is the pre-`if` node
      end
      exits
    end

    def visit_case(node, prev)
      exits = []
      Array(node.conditions).each do |when_node|
        guard = Array(when_node.conditions).map { |c| source_of(c) }.join(", ")
        before = @edges.size
        exit_id = walk(when_node.statements, prev)
        mark_entry_conditional(before, prev, guard)
        exits |= to_list(exit_id)
      end
      exits |=
        if node.else_clause
          to_list(walk(node.else_clause.statements, prev))
        else
          to_list(prev)
        end
      exits
    end

    # The else/elsif chain, across prism versions (IfNode uses #subsequent, older
    # #consequent; Unless/Case expose #else_clause). Returns the node or nil.
    def branch_else(node)
      return node.subsequent if node.respond_to?(:subsequent)
      return node.else_clause if node.respond_to?(:else_clause)
      return node.consequent if node.respond_to?(:consequent)
      nil
    end

    # The edges added since `before` that enter the body's first node (one per
    # incoming prev) are the conditional entry: relabel them :conditional + guard.
    def mark_entry_conditional(before, prev, guard)
      prevs = to_list(prev)
      entry = @edges[before..].select { |e| prevs.include?(e.from) }
      return if entry.empty?
      first_to = entry.first.to
      entry.select { |e| e.to == first_to }.each do |e|
        e.kind = :conditional
        e.guard = guard
      end
    end

    # continue_if's false path halts the workflow: a :terminal edge to the shared
    # synthetic "halt" sink. Like "start", the sink is a virtual endpoint id, not
    # a real node, so it never pollutes the durable-step node list.
    def attach_terminal(_call, id)
      add_edge(id, "halt", :terminal, "condition false")
      id
    end

    # Best-effort source text of a predicate node (for guard labels). Falls back
    # to the node type when slicing isn't available.
    def source_of(node)
      node.respond_to?(:slice) ? node.slice : node.class.name.split("::").last
    end

    def negate(guard) = "!(#{guard})"

    def to_list(value) = value.is_a?(Array) ? value : [value]

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
      to_list(prev).each { |p| add_edge(p, node.id, :seq) }

      if call.name == :branch && call.block
        emit_branch_children(call.block, node)
        (@branches ||= {})[name] = node.id
      elsif kind == :merge
        positional_args(call).each do |arg|
          bname = literal_value(arg)
          src = @branches && @branches[bname]
          add_edge(src, node.id, :join) if src
        end
      end
      node.id
    end

    # A branch's spawn/spawn_each calls each become one child-group node, reached
    # by a :fanout edge. Children are keyed <wf.key>$<branch>$<name>_* at runtime;
    # we record a prefix pattern for reference, but the dashboard overlay computes
    # fan-out status from child-workflow counts (BranchProbe), not this pattern.
    def emit_branch_children(block, branch_node)
      body = block.is_a?(Prism::BlockNode) ? block.body : nil
      stmts =
        case body
        when Prism::StatementsNode then body.body
        else Array(body)
        end
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
