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

    # Which argument carries the step NAME, per the real DSL signatures in
    # executor/methods. `pos` is the 0-based positional index; `kw` = whether a
    # `name:` keyword overrides it. `wait(duration, name)` is the one primitive
    # whose name is the SECOND positional. merge_branches is special-cased in
    # step_name_for (its name joins all positional branch names).
    NAME_ARG = {
      durably_execute: {pos: 0, kw: true},
      wait: {pos: 1, kw: false},
      wait_until: {pos: 0, kw: false},
      continue_if: {pos: 0, kw: true},
      durably_repeat: {pos: 0, kw: true},
      branch: {pos: 0, kw: false}
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
      _file, method_node, defs = locate_perform
      return unavailable unless method_node

      @defs = defs # name(Symbol) => Prism::DefNode, for same-class helper tracing
      walk(method_node.body, "start") # builds @nodes/@edges as a side effect
      Definition.new(nodes: @nodes, edges: @edges, warnings: @warnings)
    rescue => e
      unavailable("analysis error: #{e.class}: #{e.message}")
    end

    private

    # The workflow's OWN perform, not the prepended ChronoForge::Executor#perform.
    # A workflow does `prepend ChronoForge::Executor`, so instance_method(:perform)
    # resolves to the executor's wrapper (owner is a Module). Walk the super chain
    # to the first perform defined on a real Class in the ancestry — the user's.
    def user_perform
      um = @klass.instance_method(:perform)
      um = um.super_method while um && !um.owner.is_a?(Class)
      um
    rescue NameError
      nil
    end

    # Resolve perform's source file, parse it, and collect the instance-method
    # DefNodes that lexically belong to the SAME class body as the bound perform
    # (for same-class helper tracing). Scoping to the containing class avoids a
    # bare helper call resolving to a same-named method in a DIFFERENT class.
    def locate_perform
      loc = user_perform&.source_location
      return [nil, nil, {}] unless loc && File.readable?(loc.first)

      file, line = loc
      root = Prism.parse_file(file).value
      klass = innermost_class_containing(root, line)
      return [file, nil, {}] unless klass

      defs = {}
      perform = nil
      class_method_defs(klass).each do |d|
        defs[d.name] = d
        # A file may hold several workflow classes (each with its own #perform);
        # bind to the one whose `def` starts on this method's source line.
        perform = d if d.name == :perform && d.location.start_line == line
      end
      [file, perform, defs]
    end

    # The DEEPEST Class/Module node whose line range covers `line` (a class nested
    # in a module returns the inner class, since descent reassigns last-wins).
    def innermost_class_containing(node, line)
      found = nil
      visit = ->(n) do
        return unless n.is_a?(Prism::Node)
        if (n.is_a?(Prism::ClassNode) || n.is_a?(Prism::ModuleNode)) &&
            n.location.start_line <= line && line <= n.location.end_line
          found = n
        end
        n.compact_child_nodes.each { |c| visit.call(c) }
      end
      visit.call(node)
      found
    end

    # DefNodes directly in this class/module body — NOT inside a deeper nested
    # class/module (those belong to other classes).
    def class_method_defs(klass)
      out = []
      collect = ->(n) do
        return unless n.is_a?(Prism::Node)
        return if n.is_a?(Prism::ClassNode) || n.is_a?(Prism::ModuleNode)
        out << n if n.is_a?(Prism::DefNode)
        n.compact_child_nodes.each { |c| collect.call(c) }
      end
      klass.compact_child_nodes.each { |c| collect.call(c) }
      out
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
      when Prism::BeginNode
        visit_begin(stmt, prev)
      when Prism::ReturnNode
        # An early `return` exits the run: a :terminal edge to the shared "halt"
        # sink from each live predecessor. When the return sits inside an if/unless
        # (the common `return unless ready?` form), mark_entry_conditional stamps
        # this edge with the guard. This path does NOT continue, so it contributes
        # no exit — return [] so the next statement builds only from the skip path.
        to_list(prev).each { |p| add_edge(p, "halt", :terminal) }
        []
      else
        if (call = durable_call(stmt))
          id = emit_durable(call, prev)
          id = attach_terminal(call, id) if call.name == :continue_if
          id
        elsif (helper = traceable_helper(stmt))
          trace_helper(helper, prev)
        elsif loop_with_durable?(stmt)
          @warnings << "durable step inside a loop (#{stmt.class.name.split("::").last}) — " \
            "count is data-dependent; shown once, not unrolled"
          walk_loop_body(stmt, prev)
        else
          prev
        end
      end
    end

    # A bare (receiverless/self) call to a same-file method whose body contains a
    # durable call — worth tracing inline. Recursion-guarded via @tracing.
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
      if node.is_a?(Prism::CallNode) && DURABLE.key?(node.name) &&
          (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        return true
      end
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

    # Walk a loop body ONCE so contained steps appear (with the warning), not
    # unrolled. Handles both keyword loops and iterator blocks.
    def walk_loop_body(node, prev)
      body =
        case node
        when Prism::CallNode then node.block.is_a?(Prism::BlockNode) ? node.block.body : nil
        else node.respond_to?(:statements) ? node.statements : nil
        end
      walk(body, prev)
    end

    # if/unless: walk the body under a guard, then expose BOTH the body exit(s)
    # and the skip path (pre-`if` node, or the else-branch exits) so the next
    # statement is reachable every way. Returns a list of exit ids.
    def visit_conditional(node, prev)
      raw = source_of(node.predicate)
      unless_node = node.is_a?(Prism::UnlessNode)
      # `unless P` runs its body when P is FALSE and its else when P is TRUE.
      body_guard = unless_node ? negate(raw) : raw
      else_guard = unless_node ? raw : negate(raw)

      before = @edges.size
      body_exit = walk(node.statements, prev)
      mark_entry_conditional(before, prev, body_guard)

      exits = to_list(body_exit)
      if (sub = branch_else(node))
        before_else = @edges.size
        else_stmts = sub.is_a?(Prism::ElseNode) ? sub.statements : sub
        else_exit = walk(else_stmts, prev)
        mark_entry_conditional(before_else, prev, else_guard)
        exits |= to_list(else_exit)
      else
        exits |= to_list(prev) # no else: skip path is the pre-`if` node
      end
      exits
    end

    # begin/rescue/else/ensure: walk the main body and every rescue clause so
    # durable calls in either path appear. Each is an alternative path from the
    # same `prev`; their exits rejoin. (ensure always runs, so it follows all.)
    def visit_begin(node, prev)
      exits = to_list(walk(node.statements, prev))
      rescue_clause = node.rescue_clause
      while rescue_clause
        exits |= to_list(walk(rescue_clause.statements, prev))
        rescue_clause = rescue_clause.subsequent
      end
      exits |= to_list(walk(node.else_clause.statements, prev)) if node.else_clause
      exits = to_list(walk(node.ensure_clause.statements, exits)) if node.ensure_clause
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

    # The edges added since `before` whose `from` is one of the incoming `prev`
    # ids are exactly the conditional's ENTRY edges (internal body edges originate
    # at body nodes, not at `prev`). Relabel them :conditional and COMPOSE the
    # guard with any existing one so an outer conditional wrapping an inner one
    # yields `outer && inner` on every entry edge.
    def mark_entry_conditional(before, prev, guard)
      prevs = to_list(prev)
      @edges[before..].each do |e|
        next unless prevs.include?(e.from)
        # Keep a terminal (early-return / continue_if false) edge dashed; only its
        # guard is composed. Other entry edges become conditional.
        e.kind = :conditional unless e.kind == :terminal
        e.guard = e.guard ? "#{guard} && #{e.guard}" : guard
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
      raw = node.respond_to?(:slice) ? node.slice : node.class.name.split("::").last
      # Collapse internal whitespace/newlines and truncate so guard labels stay
      # renderable on a single Mermaid edge.
      compact = raw.to_s.gsub(/\s+/, " ").strip
      (compact.length > 60) ? "#{compact[0, 59]}…" : compact
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
        label: ((kind == :merge) ? merge_label(call) : label_for(call.name, name)),
        step_name: step_name,
        step_name_pattern: ("#{prefix_for(call.name)}$" if dynamic),
        warnings: (dynamic ? ["#{call.name}: dynamic name — bound by prefix/ordinal"] : [])
      )
      to_list(prev).each { |p| add_edge(p, node.id, :seq) }

      if call.name == :branch && call.block
        emit_branch_children(call.block, node)
        (@branches ||= {})[name] = node.id if name # skip dynamic branch names
      elsif kind == :merge
        positional_args(call).each do |arg|
          bname = literal_value(arg)
          next unless bname # a dynamic merge name matches no recorded branch
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

    # Resolve the step NAME literal from a durable call, per NAME_ARG. Returns
    # [name_string_or_nil, dynamic?]. dynamic? is true when the name can't be
    # resolved to a literal statically. (merge_branches resolves via all
    # positionals in step_name_for; its `name` here is just the first branch.)
    def resolved_name(call)
      spec = NAME_ARG.fetch(call.name, {pos: 0, kw: true})
      if spec[:kw] && (override = keyword_literal(call, :name))
        return [override, false]
      end
      lit = literal_value(positional_args(call)[spec[:pos]])
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

    # A merge node lists ALL its literal branch names, e.g. "merge_branches a, b"
    # (source order). Falls back to the bare DSL name if any name is non-literal.
    def merge_label(call)
      names = positional_args(call).map { |a| literal_value(a) }
      return call.name.to_s if names.empty? || names.any?(&:nil?)
      "#{call.name} #{names.join(", ")}"
    end

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
