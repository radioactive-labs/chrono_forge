require "test_helper"

class SmokeTest < ActionDispatch::IntegrationTest
  test "engine root renders" do
    get "/chrono_forge"
    assert_response :success
    assert_match "ChronoForge Dashboard", response.body
  end
end
