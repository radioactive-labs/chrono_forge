require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "long_wait_threshold defaults to an hour" do
    assert_equal 3600, ChronoForge::Dashboard.config.long_wait_threshold
  end

  test "page_size and polling defaults" do
    assert_equal 50, ChronoForge::Dashboard.config.page_size
    assert_equal 15, ChronoForge::Dashboard.config.polling_interval
  end

  # Stranded detection reads the gem's reap_stale_after (not a dashboard config),
  # so the dashboard flags exactly what Workflow.reap_stalled reaps.
  test "reap_stale_after comes from the gem, defaulting to 3x max_duration" do
    assert_equal ChronoForge.config.max_duration * 3, ChronoForge.config.reap_stale_after
  end
end
