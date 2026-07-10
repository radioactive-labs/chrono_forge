module ChronoForge
  module Dashboard
    # Workflows stranded in :running — still locked, but their lock hasn't been
    # refreshed within reap_stale_after, so no worker is driving them (the worker
    # was hard-killed mid-pass). This is exactly the set ChronoForge::Workflow
    # .reap_stalled re-enqueues; the page reads the reaper's own criterion so the
    # two never disagree. Top-level and branch children alike, like the reaper.
    class StrandedController < BaseController
      # Bound the scan: at scale there can be a large backlog, so we examine at
      # most CAP (oldest lock first — most stranded) and let the bulk reap sweep
      # the rest server-side.
      CAP = 500

      def index
        cutoff = ChronoForge.config.reap_stale_after.ago
        scope = ChronoForge::Workflow
          .where(state: ChronoForge::Workflow.states[:running])
          .where(locked_at: ...cutoff)
          .order(locked_at: :asc)
          .limit(CAP + 1)
          .to_a
        @capped = scope.size > CAP
        @stranded = scope.first(CAP)
        @cap = CAP
        @stale_after = ChronoForge.config.reap_stale_after
      end
    end
  end
end
