require "test_helper"

class StepNameParserTest < ActiveSupport::TestCase
  P = ChronoForge::Dashboard::StepNameParser

  test "durably_execute" do
    r = P.parse("durably_execute$charge_card")
    assert_equal :execute, r.kind
    assert_equal "charge_card", r.name
    assert_nil r.timestamp
  end

  test "wait_until" do
    assert_equal :wait, P.parse("wait_until$paid?").kind
    assert_equal "paid?", P.parse("wait_until$paid?").name
  end

  test "continue_if" do
    assert_equal :continue, P.parse("continue_if$ready?").kind
    assert_equal "ready?", P.parse("continue_if$ready?").name
  end

  test "durably_repeat coordination" do
    r = P.parse("durably_repeat$remind")
    assert_equal :repeat_coordination, r.kind
    assert_equal "remind", r.name
    assert_nil r.timestamp
  end

  test "durably_repeat run" do
    r = P.parse("durably_repeat$remind$1717000000")
    assert_equal :repeat_run, r.kind
    assert_equal "remind", r.name
    assert_equal 1717000000, r.timestamp
  end

  test "unknown is preserved, never raises" do
    r = P.parse("legacy_thing")
    assert_equal :unknown, r.kind
    assert_equal "legacy_thing", r.raw
  end
end
