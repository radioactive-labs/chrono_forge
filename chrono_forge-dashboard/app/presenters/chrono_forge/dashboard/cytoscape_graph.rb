module ChronoForge
  module Dashboard
    # Builds Cytoscape.js "elements" (nodes + edges) from overlay node hashes and
    # Definition edges. Unlike a text-DSL renderer, this emits STRUCTURED data the
    # client consumes directly (via JSON.parse), so node labels and guard text need
    # no escaping — the whole class of Mermaid string-grammar bugs disappears.
    # Rendering-only: no DB, no analysis.
    class CytoscapeGraph
      def initialize(nodes, edges)
        @nodes = nodes
        @edges = edges
      end

      def to_h
        {nodes: node_elements, edges: edge_elements}
      end

      private

      def node_elements
        real_ids = @nodes.map { |n| n[:id] }.to_set
        real = @nodes.map do |n|
          data = {id: n[:id], label: n[:label].to_s, step_name: n[:step_name]}
          # Run aggregates the overlay computed for this node: a repeat's execution
          # count and a branch fan-out's per-state child tally. Forwarded so the
          # client can label them (nil/absent for other kinds).
          data[:repetitions] = n[:repetitions] if n[:repetitions]
          data[:counts] = n[:counts] if n[:counts]&.any?
          {data: data, classes: "kind-#{n[:kind]} status-#{n[:status]}"}
        end
        # start/halt (and any other virtual endpoint) are edge targets but not in
        # the node list; Cytoscape rejects edges to missing nodes, so synthesize
        # them as endpoint nodes.
        endpoints = @edges.flat_map { |e| [e.from, e.to] }.uniq.reject { |id| real_ids.include?(id) }
        real + endpoints.map { |id| {data: {id: id, label: id}, classes: "kind-endpoint"} }
      end

      def edge_elements
        @edges.each_with_index.map do |e, i|
          {
            data: {id: "e#{i}", source: e.from, target: e.to, label: e.guard.to_s},
            classes: "kind-#{e.kind}"
          }
        end
      end
    end
  end
end
