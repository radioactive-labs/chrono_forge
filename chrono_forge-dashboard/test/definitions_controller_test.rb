require "test_helper"

class DefinitionsControllerTest < ActionDispatch::IntegrationTest
  include DashboardTestHelpers

  setup { ChronoForge::Dashboard.configure { |c| c.authentication = :none } }
  teardown { ChronoForge::Dashboard.reset_configuration! }

  def test_show_renders_the_graph_container_and_elements
    wf = create_workflow(key: "def-page", state: :running, job_class: "DefinitionLinearWorkflow")
    get "/chrono_forge/workflows/#{wf.id}/definition"
    assert_response :success
    assert_match(/id="cf-graph"/, response.body)
    # The structured graph is embedded as JSON (step names appear in node data).
    assert_match(/durably_execute/, response.body)
    assert_match(%r{assets/definition_graph\.js}, response.body)
  end

  # The graph page opts out of the polling refresh: the JS gates on the
  # data-poll-region attribute, so its absence keeps the morph refresh from
  # wiping the live Cytoscape canvas. (The #cf-poll-region id stays — it is only
  # the morph target — but must not carry data-poll-region here.)
  def test_definition_page_opts_out_of_polling
    wf = create_workflow(key: "def-nopoll", state: :running, job_class: "DefinitionLinearWorkflow")
    get "/chrono_forge/workflows/#{wf.id}/definition"
    assert_response :success
    assert_match(/id="cf-poll-region"/, response.body)
    assert_no_match(/data-poll-region/, response.body)
  end

  def test_unknown_class_degrades_gracefully
    wf = create_workflow(key: "def-unknown", state: :running, job_class: "Nope::DoesNotExist")
    get "/chrono_forge/workflows/#{wf.id}/definition"
    assert_response :success
    assert_match(/statically analyz/i, response.body)
  end
end
