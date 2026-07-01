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
        guard = e.guard.to_s.strip
        label = guard.empty? ? "" : "|#{sanitize(guard)}|"
        arrow = (e.kind == :terminal) ? "-.->" : "-->"
        [e.from, "#{arrow}#{label}", e.to].join(" ")
      end

      def used_statuses = @nodes.map { |n| n[:status] }.uniq.select { |s| CLASS_DEFS.key?(s) }

      def sanitize(s) = s.gsub('"', "'").gsub(/[\[\]{}|]/, " ").strip
    end
  end
end
