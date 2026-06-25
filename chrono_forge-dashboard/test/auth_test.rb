require "test_helper"

class AuthTest < ActionDispatch::IntegrationTest
  def teardown
    ChronoForge::Dashboard.reset_configuration!
  end

  test "raises when nothing is configured" do
    assert_raises(ChronoForge::Dashboard::AuthenticationNotConfigured) { get "/chrono_forge" }
  end

  test "http basic accepts correct credentials" do
    ChronoForge::Dashboard.configure { |c| c.http_basic = { username: "a", password: "b" } }
    get "/chrono_forge", headers: { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("a", "b") }
    assert_response :success
  end

  test "http basic rejects wrong credentials" do
    ChronoForge::Dashboard.configure { |c| c.http_basic = { username: "a", password: "b" } }
    get "/chrono_forge", headers: { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("a", "x") }
    assert_response :unauthorized
  end

  test "hook can deny" do
    ChronoForge::Dashboard.configure { |c| c.authenticate { |ctrl| ctrl.head(:forbidden) } }
    get "/chrono_forge"
    assert_response :forbidden
  end

  test "authentication :none permits" do
    ChronoForge::Dashboard.configure { |c| c.authentication = :none }
    get "/chrono_forge"
    assert_response :success
  end
end
