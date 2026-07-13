require "test_helper"

class DashboardHelperTest < ActionView::TestCase
  include ChronoForge::Dashboard::DashboardHelper

  test "cf_pct: nil, zero, tiny, sub-one, and whole rates" do
    assert_equal "—", cf_pct(nil)
    assert_equal "0%", cf_pct(0)
    assert_equal "<0.01%", cf_pct(0.000008) # 0.0008% — must stay visible
    assert_equal "0.5%", cf_pct(0.005)
    assert_equal "25%", cf_pct(0.25)
    assert_equal "100%", cf_pct(1.0)
  end

  test "cf_secs: scales to the two most-significant units" do
    assert_equal "—", cf_secs(nil)
    assert_equal "0s", cf_secs(0)
    assert_equal "45s", cf_secs(45)
    assert_equal "1m 04s", cf_secs(64)
    assert_equal "2m 00s", cf_secs(120)
    assert_equal "1h 02m", cf_secs(3720)        # 1h 2m
    assert_equal "3h 00m", cf_secs(10800)       # exactly 3h
    assert_equal "1d 21h", cf_secs(162768)      # the "2712m 48s" case
    assert_equal "2d 00h", cf_secs(172800)      # exactly 2d
  end

  test "cf_bar_width: zero-max guard and 5% quantization" do
    assert_equal "cf-bar-0", cf_bar_width(5, 0)   # no divide-by-zero
    assert_equal "cf-bar-100", cf_bar_width(10, 10)
    assert_equal "cf-bar-50", cf_bar_width(5, 10)
    assert_equal "cf-bar-25", cf_bar_width(1, 4)   # 25% exact
    assert_equal "cf-bar-35", cf_bar_width(1, 3)   # 33.3% -> nearest 5
  end

  test "cf_poll_label: off, seconds, minutes" do
    assert_equal "off", cf_poll_label(0)
    assert_equal "5s", cf_poll_label(5)
    assert_equal "30s", cf_poll_label(30)
    assert_equal "1m", cf_poll_label(60)
    assert_equal "5m", cf_poll_label(300)
  end

  test "cf_poll_options come from config" do
    assert_equal [0, 5, 10, 15, 30, 60, 300], cf_poll_options
    ChronoForge::Dashboard.configure { |c| c.polling_interval_options = [0, 7] }
    assert_equal [0, 7], cf_poll_options
  ensure
    ChronoForge::Dashboard.reset_configuration!
  end

  test "cf_capped: shows N+ at the cap" do
    assert_equal "12", cf_capped(12, 5000)
    assert_equal "5000+", cf_capped(5000, 5000)
  end

  test "cf_state_order: active->terminal, unknown states appended" do
    keys = %w[completed idle failed running stalled mystery]
    assert_equal %w[running idle stalled failed completed mystery], cf_state_order(keys)
  end

  # A minimal stand-in for a workflow row (only what cf_stranded? touches).
  def wf(state:, locked_at:)
    Struct.new(:state, :locked_at) do
      def running? = state == :running
    end.new(state, locked_at)
  end

  # reap_stale_after defaults to 3x max_duration = 30 min out of the box.
  test "cf_stranded?: flags a running workflow whose lock has gone stale" do
    assert cf_stranded?(wf(state: :running, locked_at: 40.minutes.ago))   # lock older than reap_stale_after
    refute cf_stranded?(wf(state: :running, locked_at: 5.minutes.ago))    # fresh lock — worker alive
    refute cf_stranded?(wf(state: :running, locked_at: nil))              # not locked
    refute cf_stranded?(wf(state: :completed, locked_at: 5.hours.ago))    # not running
  end

  test "cf_stranded?: tracks a custom reap_stale_after" do
    ChronoForge.config.reap_stale_after = 10.minutes
    assert cf_stranded?(wf(state: :running, locked_at: 15.minutes.ago))
    refute cf_stranded?(wf(state: :running, locked_at: 5.minutes.ago))
  ensure
    ChronoForge.config.reap_stale_after = nil
  end

  test "cf_attempts_note: hidden at 1, kind-aware wording and tone" do
    assert_nil cf_attempts_note(:execute, 1, "completed")
    assert_equal({text: "3 attempts", tone: :crit, title: "Ran 3 times — 2 retries after the first attempt"},
      cf_attempts_note(:execute, 3, "failed"))
    assert_equal({text: "2 attempts", tone: :warn, title: "Ran 2 times — 1 retry after the first attempt"},
      cf_attempts_note(:execute, 2, "completed"))
    assert_equal({text: "checked 3×", tone: :muted, title: "Polled 3 times before this step resolved"},
      cf_attempts_note(:wait, 3, "completed"))
    assert_nil cf_attempts_note(:repeat_coordination, 4, "pending") # iterations shown instead
  end

  test "cf_meter_title: adds share-of-longest and absolute span the number can't show" do
    from = Time.utc(2026, 7, 9, 22, 35, 39)
    to = Time.utc(2026, 7, 9, 22, 39, 39) # 240s
    title = cf_meter_title(240, 420, from, to)
    assert_includes title, "4m 00s"
    assert_includes title, "57% of the longest step"
    assert_includes title, "2026-07-09T22:35:39Z → 2026-07-09T22:39:39Z"
  end

  test "cf_duration_bar: sqrt scale keeps short steps visible and clamps" do
    assert_equal "cf-bar-0", cf_duration_bar(nil, 100)
    assert_equal "cf-bar-0", cf_duration_bar(10, 0)     # no divide-by-zero
    assert_equal "cf-bar-100", cf_duration_bar(100, 100)
    refute_equal "cf-bar-0", cf_duration_bar(2, 420)    # 2s of 7m still shows a sliver
    assert_equal "cf-bar-0", cf_duration_bar(-5, 100)   # backwards step: no bar, no sqrt-domain crash
  end

  Bucket = Struct.new(:day, :completed, :failed) do
    def terminal = completed + failed
  end

  test "cf_day_rate / cf_day_flagged?: completion rate and failure-spike flag" do
    healthy = Bucket.new("Jul 09", 99, 1)
    spike = Bucket.new("Jul 08", 61, 39)
    empty = Bucket.new("Jul 07", 0, 0)
    assert_in_delta 0.99, cf_day_rate(healthy), 0.001
    assert_nil cf_day_rate(empty)                 # nothing terminated
    refute cf_day_flagged?(healthy)               # 1% failure — not flagged
    assert cf_day_flagged?(spike)                 # 39% failure — flagged
    refute cf_day_flagged?(empty)
  end

  test "cf_window_trend: newer-half minus older-half, in points; nil when thin" do
    assert_nil cf_window_trend([])
    assert_nil cf_window_trend([Bucket.new("d", 5, 0)])         # one bucket, nothing to compare
    # older half 50% complete, newer half 100% complete → +50 completion, -50 failure
    buckets = [Bucket.new("d1", 5, 5), Bucket.new("d2", 10, 0)]
    trend = cf_window_trend(buckets)
    assert_in_delta 50.0, trend[:completion], 0.1
    assert_in_delta(-50.0, trend[:failure], 0.1)
  end

  test "cf_row_duration_secs: elapsed for live, final for ran-and-stopped, nil for parked" do
    assert_equal 30, cf_row_duration_secs(WorkflowStub.new(:completed, Time.current - 30, Time.current))
    assert_equal 30, cf_row_duration_secs(WorkflowStub.new(:failed, Time.current - 30, Time.current))
    assert_equal 30, cf_row_duration_secs(WorkflowStub.new(:stalled, Time.current - 30, Time.current)) # ran, then halted
    assert_nil cf_row_duration_secs(WorkflowStub.new(:idle, Time.current - 3600, nil))       # parked on a wait
    assert_nil cf_row_duration_secs(WorkflowStub.new(:completed, nil, nil))                   # never started
    live = cf_row_duration_secs(WorkflowStub.new(:running, Time.current - 120, nil))
    assert_operator live, :>=, 119
    # ending before start (clock skew / bad data) → unknown, not a negative
    assert_nil cf_row_duration_secs(WorkflowStub.new(:completed, Time.current, Time.current - 30))
  end

  # Minimal stand-in for a Workflow row — only the fields the helper reads.
  WorkflowStub = Struct.new(:state, :started_at, :ended_at) do
    def completed_at = (state == :completed) ? ended_at : nil
    def updated_at = ended_at
    def running? = state == :running
    def failed? = state == :failed
    def stalled? = state == :stalled
  end
end
