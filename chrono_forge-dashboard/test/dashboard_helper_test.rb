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

  # A minimal stand-in for a workflow row (only what the long-run helpers touch).
  def wf(state:, started_at:, job_class: "OrderWorkflow")
    Struct.new(:state, :started_at, :job_class) do
      def running? = state == :running
    end.new(state, started_at, job_class)
  end

  test "cf_run_overdue?: flags a running workflow past its threshold" do
    assert cf_run_overdue?(wf(state: :running, started_at: 2.hours.ago))
    refute cf_run_overdue?(wf(state: :running, started_at: 2.minutes.ago))
    refute cf_run_overdue?(wf(state: :completed, started_at: 5.hours.ago)) # not running
    refute cf_run_overdue?(wf(state: :running, started_at: nil))
  end

  test "cf_run_overdue?: honors per-class thresholds and opt-out" do
    ChronoForge::Dashboard.configure { |c| c.long_run_thresholds = {"Fast" => 60, "Never" => nil} }
    assert cf_run_overdue?(wf(state: :running, started_at: 2.minutes.ago, job_class: "Fast"))
    refute cf_run_overdue?(wf(state: :running, started_at: 5.hours.ago, job_class: "Never"))
  ensure
    ChronoForge::Dashboard.reset_configuration!
  end

  test "cf_attempts_note: hidden at 1, kind-aware wording and tone" do
    assert_nil cf_attempts_note(:execute, 1, "completed")
    assert_equal({text: "3 attempts", tone: :crit}, cf_attempts_note(:execute, 3, "failed"))
    assert_equal({text: "2 attempts", tone: :warn}, cf_attempts_note(:execute, 2, "completed"))
    assert_equal({text: "checked 3×", tone: :muted}, cf_attempts_note(:wait, 3, "completed"))
    assert_nil cf_attempts_note(:repeat_coordination, 4, "pending") # iterations shown instead
  end

  test "cf_duration_bar: sqrt scale keeps short steps visible and clamps" do
    assert_equal "cf-bar-0", cf_duration_bar(nil, 100)
    assert_equal "cf-bar-0", cf_duration_bar(10, 0)     # no divide-by-zero
    assert_equal "cf-bar-100", cf_duration_bar(100, 100)
    refute_equal "cf-bar-0", cf_duration_bar(2, 420)    # 2s of 7m still shows a sliver
  end
end
