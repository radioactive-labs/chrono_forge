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

      # A capped count: shows "5000+" once the count saturates its cap.
      def cf_capped(count, cap)
        (count >= cap) ? "#{cap}+" : count.to_s
      end

      # Relative time with the absolute timestamp on hover.
      def cf_ago(t)
        return "—" unless t
        tag.span("#{time_ago_in_words(t)} ago", title: t.iso8601, class: "cursor-help")
      end

      # Human duration between two times (e.g. "1m 04s"); "—" if unfinished.
      def cf_duration(from, to)
        return "—" unless from && to
        secs = (to - from).to_i
        (secs < 60) ? "#{secs}s" : "#{secs / 60}m #{(secs % 60).to_s.rjust(2, "0")}s"
      end

      # Concise latency summary (avg + most recent) from a list of run seconds.
      def cf_latency_summary(latencies)
        return "—" if latencies.blank?
        avg = (latencies.sum.to_f / latencies.size).round
        "avg #{avg}s · last #{latencies.last}s"
      end

      # Short, readable label for a parsed step kind.
      KIND_LABELS = {
        execute: "execute", wait: "wait", continue: "continue if",
        repeat_coordination: "repeat", repeat_run: "run",
        branch: "branch", merge: "merge", unknown: "step"
      }.freeze

      def cf_kind_label(kind)
        KIND_LABELS.fetch(kind, kind.to_s)
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
