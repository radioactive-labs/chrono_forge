require "test_helper"

class ChronoForgeTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def test_version
    assert ChronoForge::VERSION
  end

  def test_kitchen_sink_runs_successfully
    KitchenSink.perform_later("identifier", kwarg: "durable", options: {option1: 1})

    perform_all_jobs

    assert_equal ChronoForge::Workflow.count, 1, "ONLY one workflow exists"

    workfow = ChronoForge::Workflow.first

    assert workfow.completed?, "workflow should be completed"

    assert_equal workfow.key, "identifier"
    assert_equal workfow.job_class, "KitchenSink"
    assert_equal workfow.kwargs, {"kwarg" => "durable"}
    assert_equal workfow.options, {"option1" => 1}

    assert workfow.context["order_id"], "order_id should be set"
    assert workfow.context["processed_at"], "processed_at should be set"
    assert workfow.context["completed_at"], "completed_at should be set"

    refute workfow.locked_by, "workflow should be unlocked: locked_by"

    assert workfow.started_at, "workflow tracking dates should be set: started_at"
    assert workfow.completed_at, "workflow tracking dates should be set: completed_at"

    refute workfow.locked_at, "workflow should be unlocked: locked_at"
    refute workfow.locked_by, "workflow should be unlocked: locked_by"

    assert_equal workfow.execution_logs.size, 5, "there should be 5 executions"
    assert_equal workfow.execution_logs.pluck(:step_name), [
      "wait_until$payment_confirmed?",
      "wait$fraud_check_delay",
      "durably_execute$process_order",
      "durably_execute$complete_order",
      "$workflow_completion$"
    ]

    assert_equal workfow.error_logs.size, 0, "no errors should have occurred"
    assert ChronoForge::Workflow.last.completed?
  end
end
