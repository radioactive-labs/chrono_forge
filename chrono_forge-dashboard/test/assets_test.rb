require "test_helper"

class AssetsTest < ActionDispatch::IntegrationTest
  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  test "serves css with cache header" do
    get "/chrono_forge/assets/dashboard.css"
    assert_response :success
    assert_equal "text/css", response.media_type
    assert_match "max-age", response.headers["Cache-Control"]
  end

  test "serves js" do
    get "/chrono_forge/assets/dashboard.js"
    assert_response :success
    assert_includes ["application/javascript", "text/javascript"], response.media_type
  end

  test "unknown asset 404s" do
    # show_exceptions = :none means routing errors propagate rather than render 404
    assert_raises(ActionController::RoutingError) { get "/chrono_forge/assets/evil.css" }
  end
end
