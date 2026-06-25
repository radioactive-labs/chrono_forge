require "test_helper"

class SmokeTest < ActionDispatch::IntegrationTest
  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "engine root renders" do
    get "/chrono_forge"
    assert_response :success
    assert_match "cf-stats", response.body
  end
end
