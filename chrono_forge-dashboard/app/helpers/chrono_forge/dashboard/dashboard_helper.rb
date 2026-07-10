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

      # Shared "chip" treatment for inline nav/action links (metrics, details,
      # repetitions, open, pagination, back) — a subtle bordered button, never an
      # underlined text link. Pass extra utility classes (margins, truncation).
      def cf_chip(extra = nil)
        ["inline-flex items-center rounded-md border border-zinc-200 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-50", extra].compact.join(" ")
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

      # A filter chip: optional colored state dot, a label, and an optional capped
      # count, with active styling. Shared by the index stats header and the
      # branch-children filter row. The caller computes +href+ (the two views build
      # different URLs); +dot+ is a state name for the colored dot, or nil for none
      # (e.g. the "all" chip, or a composite like "blocked").
      def cf_filter_chip(href, label:, active:, count: nil, cap: nil, dot: nil)
        classes = "cf-stat flex items-center gap-2 rounded-md border px-3 py-1.5 text-sm transition " +
          (active ? "border-zinc-900 bg-zinc-50" : "border-zinc-200 bg-white hover:bg-zinc-50")
        link_to href, class: classes do
          safe_join([
            dot ? cf_dot(dot) : "",
            tag.span(label, class: "text-zinc-500"),
            count ? tag.span(cf_capped(count, cap), class: "font-mono font-medium tabular-nums") : ""
          ])
        end
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

      # Whether the main region opts into auto-refresh. A page sets
      # @cf_disable_polling to opt OUT (e.g. the definition graph, whose live
      # Cytoscape canvas can't survive the poll's morph region refresh). Without a
      # [data-poll-region] the JS never starts a poll timer for the page.
      def cf_poll_region? = !@cf_disable_polling

      # A timestamp shown relative ("3 minutes ago") or absolute (raw ISO8601)
      # per the viewer's preference, with the other form available on hover.
      def cf_ago(t)
        return "—" unless t
        rel = "#{time_ago_in_words(t)} ago"
        abs = t.iso8601
        shown, hover = cf_absolute_time? ? [abs, rel] : [rel, abs]
        tag.span(shown, title: hover, class: "cursor-help")
      end

      # Like cf_ago but direction-aware: future times read "in 3 minutes", past
      # times "3 minutes ago" — for things like a poller's next scheduled check.
      def cf_when(t)
        return "—" unless t
        rel = t.future? ? "in #{time_ago_in_words(t)}" : "#{time_ago_in_words(t)} ago"
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
      # Internal bookkeeping surfaced elsewhere (the linked error is rendered
      # inline; branch poll state + spawn cursors show in the Branches panel), so
      # they'd just be noise in the timeline's metadata line. poll_token is the
      # merge poller's fencing token — pure plumbing, never user-facing.
      META_SKIP = %w[error_log_id poll poll_token cursors].freeze

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

      # Age past which a running workflow's lock is considered stale (its worker
      # gone) — the reaper's own threshold, so the dashboard flags exactly what
      # ChronoForge::Workflow.reap_stalled would re-enqueue.
      def cf_reap_stale_after = ChronoForge.config.reap_stale_after

      # A workflow stranded in :running by a hard-killed worker: still running,
      # but its lock hasn't been refreshed within reap_stale_after, so nothing is
      # driving it. This is the *only* "stuck" signal that holds — a healthy
      # workflow may legitimately run for years, so elapsed runtime says nothing.
      def cf_stranded?(workflow)
        workflow.running? && workflow.locked_at.present? &&
          workflow.locked_at < cf_reap_stale_after.ago
      end

      # How long a workflow's lock has been stale (nil if never locked).
      def cf_lock_age(workflow)
        workflow.locked_at ? (Time.current - workflow.locked_at).to_i : nil
      end

      # The attempts count made legible — nil when there's nothing worth saying.
      # The number means different things per step kind, so it's labelled per kind:
      # an execution retried, a wait/gate polled. Repeat coordination shows its
      # iteration count elsewhere, so it opts out here.
      POLLING_KINDS = %i[wait continue sleep].freeze

      def cf_attempts_note(kind, attempts, status)
        return nil if attempts.to_i <= 1
        return nil if kind == :repeat_coordination
        if POLLING_KINDS.include?(kind)
          {text: "checked #{attempts}×", tone: :muted,
           title: "Polled #{attempts} times before this step resolved"}
        else
          retries = attempts.to_i - 1
          {text: "#{attempts} attempts", tone: ((status.to_s == "failed") ? :crit : :warn),
           title: "Ran #{attempts} times — #{pluralize(retries, "retry")} after the first attempt"}
        end
      end

      # Width class (reusing the CSP-safe cf-bar-{0..100} steps) for a duration
      # meter, on a sqrt scale so a 2-second step stays visible next to a
      # 7-minute one instead of collapsing to nothing.
      def cf_duration_bar(seconds, max)
        return "cf-bar-0" if seconds.nil? || max.to_f <= 0
        pct = Math.sqrt(seconds.to_f / max) * 100
        "cf-bar-#{[(pct / 5).round * 5, 100].min}"
      end

      # A step slow enough to emphasize (a minute or more) vs. ordinary sub-minute
      # work — drives the amber meter/label in the timeline.
      def cf_slow_step?(seconds) = seconds.to_i >= 60

      # Hover text for a duration meter: what the visible number can't say —
      # this step's share of the run's longest step, and the wall-clock span it
      # covered. The bar is relative, so the percentage is what it's encoding.
      def cf_meter_title(seconds, max, from, to)
        share = (max.to_f > 0) ? (seconds.to_f / max * 100).round : 0
        "#{cf_secs(seconds)} · #{share}% of the longest step · #{from.iso8601} → #{to.iso8601}"
      end

      # A CSP-safe proportional meter (the timeline's bar, reusable): a fixed
      # track with a filled inner bar whose width is a pre-generated cf-bar-{n}
      # class. `width_class` is that class; `color_class` tints the fill.
      def cf_meter(width_class, color_class, track: "w-16", title: nil)
        content_tag(:span, class: "inline-block h-1.5 #{track} overflow-hidden rounded-full bg-zinc-200 align-middle", title: title) do
          content_tag(:span, "", class: "cf-bar #{width_class} block rounded-full #{color_class}")
        end
      end

      # --- Analytics day health ------------------------------------------------
      # A day's failure rate high enough to flag the row. Ten percent of terminal
      # workflows failing in a day is a real signal, not catch-up churn.
      DAY_FAILURE_FLAG = 0.1

      # A day's completion rate (0.0–1.0), or nil when nothing terminated.
      def cf_day_rate(bucket)
        bucket.terminal.zero? ? nil : bucket.completed.to_f / bucket.terminal
      end

      def cf_day_flagged?(bucket)
        bucket.terminal > 0 && (bucket.failed.to_f / bucket.terminal) >= DAY_FAILURE_FLAG
      end

      def cf_trend_arrow(points)
        return "—" if points.zero?
        (points > 0) ? "▲" : "▼"
      end

      def cf_trend_points(points)
        return "flat" if points.zero?
        "#{(points > 0) ? "+" : "−"}#{points.abs.round(1)}"
      end

      # Trend across the window: the newer half's completion/failure rate minus
      # the older half's, in percentage points — so a stat card can say whether
      # things are getting better or worse. Derived from the buckets already
      # loaded (no query); nil when there's too little to compare.
      def cf_window_trend(buckets)
        return nil if buckets.size < 2
        mid = buckets.size / 2
        rate = lambda do |bs|
          t = bs.sum(&:terminal)
          t.zero? ? nil : bs.sum(&:completed).to_f / t
        end
        older = rate.call(buckets[0...mid])
        newer = rate.call(buckets[mid..])
        return nil if older.nil? || newer.nil?
        pts = ((newer - older) * 100).round(1)
        {completion: pts, failure: -pts}
      end

      # Run length in seconds for a workflow row: elapsed for a live run, final
      # span for a run that ran and stopped (completed / failed / stalled), nil
      # for a parked (idle/scheduled) one whose "duration" would just be how long
      # it's been waiting on a condition, not how long it actually ran.
      def cf_row_duration_secs(workflow)
        return nil unless workflow.started_at
        ending =
          if workflow.completed_at
            workflow.completed_at
          elsif workflow.running?
            Time.current
          elsif workflow.failed? || workflow.stalled?
            workflow.updated_at
          end
        ending ? (ending - workflow.started_at).to_i : nil
      end
    end
  end
end
