require "test_helper"

class ChronoForgeTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def test_version
    assert ChronoForge::VERSION
  end

  def test_kitchen_sink_runs_successfully
    KitchenSink.perform_later("happy_path", kwarg: "durable", options: {option1: 1})

    perform_all_jobs

    workflow = ChronoForge::Workflow.last

    assert workflow.completed?, "workflow should be completed"

    assert_equal "happy_path", workflow.key
    assert_equal "KitchenSink", workflow.job_class
    assert_equal({"kwarg" => "durable"}, workflow.kwargs)
    assert_equal({"option1" => 1}, workflow.options)

    assert workflow.context["order_id"], "order_id should be set"
    assert workflow.context["processed_at"], "processed_at should be set"
    assert workflow.context["completed_at"], "completed_at should be set"

    assert workflow.started_at, "workflow tracking dates should be set: started_at"
    assert workflow.completed_at, "workflow tracking dates should be set: completed_at"

    refute workflow.locked_at, "workflow should be unlocked: locked_at"
    refute workflow.locked_by, "workflow should be unlocked: locked_by"

    assert_equal 5, workflow.execution_logs.size, "there should be 5 executions"
    assert_equal [
      "wait_until$payment_confirmed?",
      "wait$fraud_check_delay",
      "durably_execute$process_order",
      "durably_execute$complete_order",
      "$workflow_completion$"
    ], workflow.execution_logs.pluck(:step_name)

    assert_equal 0, workflow.error_logs.size, "no errors should have occurred"
  end

  def test_kitchen_sink_experiences_a_glitch
    workflow = KitchenSink.new("glitched")
    run_scenario(
      workflow,
      glitch: ["before", "#{workflow.method(:process_order).source_location[0]}:17"]
    )

    workflow = ChronoForge::Workflow.last

    assert workflow.completed?, "workflow should be completed"

    assert_equal "glitched", workflow.key

    assert workflow.context["order_id"], "order_id should be set"
    assert workflow.context["processed_at"], "processed_at should be set"
    assert workflow.context["completed_at"], "completed_at should be set"

    assert workflow.started_at, "workflow tracking dates should be set: started_at"
    assert workflow.completed_at, "workflow tracking dates should be set: completed_at"

    refute workflow.locked_at, "workflow should be unlocked: locked_at"
    refute workflow.locked_by, "workflow should be unlocked: locked_by"

    assert_equal 5, workflow.execution_logs.size, "there should be 5 executions"
    assert_equal [
      "wait_until$payment_confirmed?",
      "wait$fraud_check_delay",
      "durably_execute$process_order",
      "durably_execute$complete_order",
      "$workflow_completion$"
    ], workflow.execution_logs.pluck(:step_name)

    assert_equal 1, workflow.error_logs.size, "a single glitch should have occurred"
    assert_equal ["ChaoticJob::RetryableError"], workflow.error_logs.pluck(:error_class).uniq
  end

  def test_kitchen_sink_permanenty_fails
    KitchenSink.perform_later("permanent_failed", permanently_fail: true)

    perform_all_jobs

    workflow = ChronoForge::Workflow.last

    assert workflow.failed?, "workflow should be failed"

    assert_equal "permanent_failed", workflow.key
    assert_equal "KitchenSink", workflow.job_class
    assert_equal({"permanently_fail" => true}, workflow.kwargs)
    assert_equal({}, workflow.options)

    assert workflow.context["order_id"], "order_id should be set"
    assert workflow.context["processed_at"], "processed_at should be set"
    refute workflow.context["completed_at"], "completed_at should NOT be set"

    assert workflow.started_at, "workflow tracking dates should be set: started_at"
    refute workflow.completed_at, "workflow tracking dates should NOT be set: completed_at"

    refute workflow.locked_at, "workflow should be unlocked: locked_at"
    refute workflow.locked_by, "workflow should be unlocked: locked_by"

    assert_equal 4, workflow.execution_logs.size, "there should be 5 executions"
    assert_equal [
      "wait_until$payment_confirmed?",
      "wait$fraud_check_delay",
      "durably_execute$process_order",
      "$workflow_failure$"
    ], workflow.execution_logs.pluck(:step_name)

    assert_equal 4, workflow.error_logs.size, "workflow should have failed after 4 runs. 1 + 3 retries."
    assert_equal ["Permanent Failure"], workflow.error_logs.pluck(:error_message).uniq
  end
end
