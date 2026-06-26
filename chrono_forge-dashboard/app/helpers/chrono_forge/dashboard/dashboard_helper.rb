module ChronoForge
  module Dashboard
    module DashboardHelper
      def cf_badge(state)
        tag.span(state, class: "cf-pill cf-pill-#{state}")
      end

      def cf_dot(state)
        tag.span(class: "cf-dot cf-dot-#{state}")
      end

      def cf_time(t)
        t&.iso8601 || "—"
      end

      # Text color for an execution-log status (pending/completed/failed).
      def cf_status_color(status)
        case status
        when "completed" then "text-emerald-600"
        when "failed" then "text-rose-600"
        else "text-zinc-500"
        end
      end
    end
  end
end
