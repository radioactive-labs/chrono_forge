require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "long_run_threshold defaults to an hour" do
    assert_equal 3600, ChronoForge::Dashboard.config.long_run_threshold
  end

  test "long_run_threshold_for falls back to the global default" do
    assert_equal 3600, ChronoForge::Dashboard.config.long_run_threshold_for("AnyWorkflow")
  end

  test "long_run_threshold_for honors a per-class override" do
    ChronoForge::Dashboard.configure do |c|
      c.long_run_threshold = 3600
      c.long_run_thresholds = {"SlowBatchWorkflow" => 7200}
    end
    assert_equal 7200, ChronoForge::Dashboard.config.long_run_threshold_for("SlowBatchWorkflow")
    assert_equal 3600, ChronoForge::Dashboard.config.long_run_threshold_for("OtherWorkflow")
  end

  test "a nil per-class threshold opts that class out" do
    ChronoForge::Dashboard.configure { |c| c.long_run_thresholds = {"NeverFlag" => nil} }
    assert_nil ChronoForge::Dashboard.config.long_run_threshold_for("NeverFlag")
  end
end
