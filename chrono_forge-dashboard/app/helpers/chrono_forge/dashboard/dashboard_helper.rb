module ChronoForge
  module Dashboard
    module DashboardHelper
      def cf_badge(state)
        tag.span(state, class: "cf-badge cf-badge--#{state}")
      end

      def cf_time(t)
        t&.iso8601 || "—"
      end
    end
  end
end
