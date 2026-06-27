module ChronoForge
  module Dashboard
    module DashboardHelper
      # Display order for state counts: active work first, terminal last. Any
      # unknown states are appended so a new core state never silently vanishes.
      STATE_ORDER = %w[running idle stalled failed completed].freeze

      def cf_state_order(keys)
        (STATE_ORDER & keys) + (keys - STATE_ORDER)
      end

      def cf_badge(state)
        tag.span(state, class: "cf-pill cf-pill-#{state}")
      end

      # State badge, upgraded to "scheduled" for an idle workflow parked on a
      # wait whose wake time is still in the future — so genuinely-scheduled work
      # doesn't read as "stuck idle".
      def cf_state_badge(workflow, wait = nil)
        return cf_badge("scheduled") if workflow.idle? && wait&.scheduled?
        cf_badge(workflow.state)
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

      # Whether the viewer prefers absolute timestamps (cookie-persisted nav toggle).
      def cf_absolute_time?
        cookies[:cf_time_format] == "absolute"
      end

      # Auto-refresh interval in seconds (0 = off). A cookie-persisted nav control
      # overrides the configured default per viewer; options come from config.
      def cf_poll_options = ChronoForge::Dashboard.config.polling_interval_options

      def cf_poll_interval
        raw = cookies[:cf_poll_interval]
        return raw.to_i if raw.present? && raw.match?(/\A\d+\z/)
        ChronoForge::Dashboard.config.polling_interval.to_i
      end

      def cf_poll_label(secs)
        return "off" if secs.zero?
        (secs % 60 == 0) ? "#{secs / 60}m" : "#{secs}s"
      end

      # A timestamp shown relative ("3 minutes ago") or absolute (raw ISO8601)
      # per the viewer's preference, with the other form available on hover.
      def cf_ago(t)
        return "—" unless t
        rel = "#{time_ago_in_words(t)} ago"
        abs = t.iso8601
        shown, hover = cf_absolute_time? ? [abs, rel] : [rel, abs]
        tag.span(shown, title: hover, class: "cursor-help")
      end

      # Human duration between two times (e.g. "1m 04s"); "—" if unfinished.
      def cf_duration(from, to)
        return "—" unless from && to
        cf_secs((to - from).to_i)
      end

      # Human duration from a number of seconds, scaled to the two most-significant
      # units (e.g. "45s", "1m 04s", "3h 12m", "2d 21h"); "—" if nil.
      def cf_secs(secs)
        return "—" if secs.nil?
        secs = secs.to_i
        return "#{secs}s" if secs < 60
        return "#{secs / 60}m #{(secs % 60).to_s.rjust(2, "0")}s" if secs < 3600
        return "#{secs / 3600}h #{(secs % 3600 / 60).to_s.rjust(2, "0")}m" if secs < 86400
        "#{secs / 86400}d #{(secs % 86400 / 3600).to_s.rjust(2, "0")}h"
      end

      # Class name for a stacked-bar segment, width quantized to 5% steps so it
      # stays CSP-safe (no inline style — see .cf-bar-{0..100} in tailwind.css).
      def cf_bar_width(value, max)
        pct = (max.to_f.zero? ? 0 : (value / max.to_f * 100))
        "cf-bar-#{(pct / 5).round * 5}"
      end

      # A rate (0.0–1.0) as a percentage; "—" if nil. Keeps tiny non-zero rates
      # visible (a 0.0008% workflow-failure rate shows "<0.01%", never "0%").
      def cf_pct(rate)
        return "—" if rate.nil?
        pct = rate * 100
        return "0%" if pct.zero?
        return "<0.01%" if pct < 0.01
        (pct < 1) ? "#{pct.round(2)}%" : "#{pct.round}%"
      end

      # Concise latency summary (avg + most recent) from a list of run seconds.
      def cf_latency_summary(latencies)
        return "—" if latencies.blank?
        avg = (latencies.sum.to_f / latencies.size).round
        "avg #{avg}s · last #{latencies.last}s"
      end

      # Short, readable label for a parsed step kind.
      KIND_LABELS = {
        execute: "execute", sleep: "wait", wait: "wait until", continue: "continue if",
        repeat_coordination: "repeat", repeat_run: "run", lifecycle: "workflow",
        branch: "branch", merge: "merge", unknown: "step"
      }.freeze

      def cf_kind_label(kind)
        KIND_LABELS.fetch(kind, kind.to_s)
      end

      # Human-friendly [label, value] pairs of a step's metadata for the timeline
      # — surfaces things like a wait's resume time, a wait_until timeout, or a
      # durably_repeat's last execution. Keys are humanized; values are stringified
      # (the view truncates). Blank values are dropped.
      # Internal references shown elsewhere (the linked error is rendered inline),
      # so they'd just be noise in the metadata line.
      META_SKIP = %w[error_log_id].freeze

      def cf_meta_pairs(metadata)
        return [] unless metadata.is_a?(Hash)
        metadata
          .reject { |k, v| v.nil? || v == "" || META_SKIP.include?(k.to_s) }
          .map { |k, v| [k.to_s.tr("_", " "), v.to_s] }
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
