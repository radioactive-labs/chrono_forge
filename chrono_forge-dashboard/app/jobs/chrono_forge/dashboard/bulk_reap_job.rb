module ChronoForge
  module Dashboard
    # Reap every stranded workflow in the background so the request returns fast
    # even with a large backlog. Delegates to the gem's own sweep, which finds
    # running workflows with a stale lock (top-level and branch children) and
    # re-enqueues each — the same operation a periodic reaper would run.
    class BulkReapJob < ActiveJob::Base
      def perform = ChronoForge::Workflow.reap_stalled
    end
  end
end
