module ChronoForge
  module Dashboard
    # Per-run view of a workflow's statically-analyzed definition graph, with the
    # run's execution logs overlaid onto the nodes. Analysis is best-effort: an
    # unknown/unloadable class or an unanalyzable perform yields a warning, not a
    # 500, so the page always renders.
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

      def analyze(workflow)
        klass = workflow.job_class.constantize
        ChronoForge::DefinitionAnalyzer.call(klass) ||
          ChronoForge::Definition.new(warnings: ["perform source is not statically analyzable"])
      rescue NameError
        ChronoForge::Definition.new(
          warnings: ["workflow class #{workflow.job_class} could not be loaded; " \
            "its definition cannot be statically analyzed"]
        )
      end
    end
  end
end
