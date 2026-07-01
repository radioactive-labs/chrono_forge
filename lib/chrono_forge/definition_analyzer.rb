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
    # nothing).
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
