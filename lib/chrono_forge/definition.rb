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
      def warnings = self[:warnings] || []
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
