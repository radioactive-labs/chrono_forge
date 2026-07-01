require "test_helper"

class DefinitionsControllerTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers

  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  def test_show_renders_a_flowchart
    wf = create_workflow(key: "def-page", state: :running, job_class: "DefinitionLinearWorkflow")
    get "/chrono_forge/workflows/#{wf.id}/definition"
    assert_response :success
    assert_match(/flowchart TD/, response.body)
  end

  def test_unknown_class_degrades_gracefully
    wf = create_workflow(key: "def-unknown", state: :running, job_class: "Nope::DoesNotExist")
    get "/chrono_forge/workflows/#{wf.id}/definition"
    assert_response :success
    assert_match(/statically analyz/i, response.body)
  end
end
