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

  test "cf_capped: shows N+ at the cap" do
    assert_equal "12", cf_capped(12, 5000)
    assert_equal "5000+", cf_capped(5000, 5000)
  end

  test "cf_state_order: active->terminal, unknown states appended" do
    keys = %w[completed idle failed running stalled mystery]
    assert_equal %w[running idle stalled failed completed mystery], cf_state_order(keys)
  end
end
