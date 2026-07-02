module ChronoForge
  module Dashboard
    # Per-run view of a workflow's statically-analyzed definition graph, with the
    # run's execution logs overlaid onto the nodes. Analysis is best-effort: an
    # unknown/unloadable class or an unanalyzable perform yields a warning, not a
    # 500, so the page always renders.
    class DefinitionsController < BaseController
      def show
        # Opt out of the auto-refresh region swap: it replaces the page's HTML in
        # place, which wipes the live Cytoscape canvas (injected <script>s don't
        # re-run), leaving a blank graph. This page reloads fully instead.
        @cf_disable_polling = true
        @workflow = ChronoForge::Workflow.find(params[:id])
        definition = analyze(@workflow)
        overlay = DefinitionOverlay.new(definition, @workflow)
        @nodes = overlay.nodes
        @warnings = overlay.warnings
        @graph = CytoscapeGraph.new(@nodes, definition.edges).to_h
      end

      private

      # DefinitionAnalyzer.call always returns a Definition (an `unavailable` one on
      # any analysis failure), so the only gap is a class that won't constantize.
      def analyze(workflow)
        ChronoForge::DefinitionAnalyzer.call(workflow.job_class.constantize)
      rescue NameError
        ChronoForge::Definition.new(
          warnings: ["workflow class #{workflow.job_class} is not loadable and " \
            "cannot be statically analyzed"]
        )
      end
    end
  end
end
