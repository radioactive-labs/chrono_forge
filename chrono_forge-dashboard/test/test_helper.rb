require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use!

# Combustion's require "rails" gives us the Rails module but not ActionDispatch yet.
# We must load action_controller/railtie first so that ActionDispatch is available
# before our Engine calls isolate_namespace (which needs ActionDispatch::Routing::RouteSet).
require "combustion"
require "action_controller/railtie"

require "chrono_forge/dashboard"

Combustion.path = "test/internal"
Combustion.initialize! :active_record, :action_controller

require "rails/test_help"
require "rack/test"

module DashboardTestHelpers
  def create_workflow(key:, state: :idle, job_class: "OrderWorkflow", **attrs)
    ChronoForge::Workflow.create!(
      key: key, job_class: job_class, state: ChronoForge::Workflow.states[state],
      context: {}, kwargs: {}, options: {}, started_at: Time.current, **attrs
    )
  end
end
