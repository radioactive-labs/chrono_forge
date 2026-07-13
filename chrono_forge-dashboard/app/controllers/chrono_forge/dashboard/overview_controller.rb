module ChronoForge
  module Dashboard
    # Fleet summary. The index is a lightweight shell of turbo-frames; each
    # card and the per-class table loads from its own action below, so the shell
    # paints immediately and the heavy per-class aggregation never blocks the
    # cheap card counts (or the rest of the page). Frame responses render without
    # the layout — Turbo swaps them into the matching frame in the shell.
    class OverviewController < BaseController
      # Frame responses are live aggregates but tolerate a few seconds of
      # staleness. A short *private* cache lets Turbo's fetch reuse a frame across
      # a back/forward or quick re-visit without re-running the query — private so
      # a shared proxy never serves one viewer's counts to another. It's per-frame
      # (4 independent requests), and does nothing within a single page load; the
      # win is only the repeat visit. A host wanting cross-user dedup can layer
      # Rails.cache fragment caching on top.
      FRAME_TTL = 5.seconds
      before_action(only: %i[processed in_flight blocked classes]) { expires_in FRAME_TTL, public: false }

      # The shell opts out of the polling morph: each frame owns its own fetch.
      def index
        @cf_disable_polling = true
      end

      def processed
        @count = OverviewQuery.processed_total
        render layout: false
      end

      def in_flight
        @count = OverviewQuery.in_flight_total
        render layout: false
      end

      def blocked
        @count = OverviewQuery.blocked_total
        render layout: false
      end

      def classes
        @overview = OverviewQuery.new
        render layout: false
      end
    end
  end
end
