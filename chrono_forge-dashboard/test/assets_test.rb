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

  test "serves vendored turbo with immutable cache header" do
    get "/chrono_forge/assets/turbo.min.js"
    assert_response :success
    assert_includes ["application/javascript", "text/javascript"], response.media_type
    assert_match "max-age", response.headers["Cache-Control"]
    assert_includes response.body, "Turbo 8", "must ship a Turbo 8 build (morph stream support)"
  end

  # The polling refresh updates the list region via a Turbo morph stream rather
  # than an innerHTML swap, so idiomorph preserves in-progress filter text, focus,
  # caret, and scroll in place — no manual preservation needed. There is no JS test
  # harness, so this is a structural guard: the served script must drive the refresh
  # through the morph stream. Behavior is verified in a real browser.
  test "polling js refreshes the region via a turbo morph stream" do
    get "/chrono_forge/assets/dashboard.js"
    assert_response :success
    assert_includes response.body, "renderStreamMessage",
      "dashboard.js must refresh the poll region through Turbo's morph stream"
    assert_includes response.body, 'method="morph"',
      "the poll refresh must morph (method=\"morph\"), not innerHTML-swap, so input/scroll survive in place"
  end

  test "unknown asset 404s" do
    # show_exceptions = :none means routing errors propagate rather than render 404
    assert_raises(ActionController::RoutingError) { get "/chrono_forge/assets/evil.css" }
  end
end
