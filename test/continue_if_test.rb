require "test_helper"

class ContinueIfTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    clear_queues
  end

  def test_continue_if_condition_already_met
    unique_key = "continue_if_met_#{Time.now.to_i}_#{rand(1000)}"

    # Set up a workflow where condition is already true
    ConditionAlreadyMetJob.perform_later(unique_key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: unique_key)
    assert workflow.completed?, "workflow should be completed when condition is already met"
    assert_equal 1, workflow.context["execution_count"], "should have executed once"

    # Check execution logs
    continue_if_log = workflow.execution_logs.find { |log| log.step_name == "continue_if$condition_met?" }
    assert continue_if_log, "should have continue_if execution log"
    assert continue_if_log.completed?, "continue_if log should be completed"
    assert_equal true, continue_if_log.metadata["result"], "should record true result"
  end

  def test_continue_if_condition_not_met_requires_manual_retry
    unique_key = "continue_if_not_met_#{Time.now.to_i}_#{rand(1000)}"

    # Set up a workflow where condition is initially false
    ConditionNotMetJob.perform_later(unique_key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: unique_key)
    assert_equal "idle", workflow.state, "workflow should be in idle state waiting for manual retry"
    refute workflow.completed?, "workflow should not be completed"
    assert_equal 1, workflow.context["check_count"], "condition should have been checked once"

    # Should have no pending jobs (no automatic retry)
    assert_equal 0, enqueued_jobs.size, "should have no enqueued jobs for automatic retry"

    # Check execution logs
    continue_if_log = workflow.execution_logs.find { |log| log.step_name == "continue_if$condition_met?" }
    assert continue_if_log, "should have continue_if execution log"
    refute continue_if_log.completed?, "continue_if log should not be completed"
    assert_equal 1, continue_if_log.attempts, "should have attempted once"

    # Simulate external event that makes condition true
    workflow.context[:make_condition_true] = true
    workflow.save!

    # Manually retry the workflow
    ConditionNotMetJob.perform_later(unique_key)
    perform_all_jobs

    workflow.reload
    assert workflow.completed?, "workflow should be completed after manual retry with condition met"
    assert_equal 2, workflow.context["check_count"], "condition should have been checked twice"

    # Check that continue_if log is now completed
    continue_if_log.reload
    assert continue_if_log.completed?, "continue_if log should be completed after successful retry"
    assert_equal true, continue_if_log.metadata["result"], "should record true result"
  end

  def test_continue_if_with_condition_error
    unique_key = "continue_if_error_#{Time.now.to_i}_#{rand(1000)}"

    ConditionErrorJob.perform_later(unique_key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: unique_key)
    assert workflow.stalled?, "workflow should be stalled after condition error"

    # Check execution logs
    continue_if_log = workflow.execution_logs.find { |log| log.step_name == "continue_if$error_condition?" }
    assert continue_if_log, "should have continue_if execution log"
    assert continue_if_log.failed?, "continue_if log should be failed"
    assert_equal "StandardError", continue_if_log.error_class, "should record error class"
    assert_includes continue_if_log.error_message, "Simulated condition error", "should record error message"
  end

  def test_continue_if_idempotent_on_replay
    unique_key = "continue_if_idempotent_#{Time.now.to_i}_#{rand(1000)}"

    # First execution - condition is false, workflow halts
    IdempotentJob.perform_later(unique_key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: unique_key)
    assert_equal "idle", workflow.state, "workflow should be in idle state"
    assert_equal 1, workflow.context["check_count"], "condition should have been checked once"

    # Simulate external condition becoming true
    workflow.context[:make_condition_true] = true
    workflow.save!

    # Retry the workflow - should continue from where it left off
    IdempotentJob.perform_later(unique_key)
    perform_all_jobs

    workflow.reload
    assert workflow.completed?, "workflow should be completed"
    assert_equal 2, workflow.context["check_count"], "condition should have been checked exactly twice total"
    assert_equal 1, workflow.context["post_continue_count"], "post-continue logic should execute once"

    # Check execution logs
    continue_if_logs = workflow.execution_logs.select { |log| log.step_name == "continue_if$condition_met?" }
    assert_equal 1, continue_if_logs.size, "should have exactly one continue_if execution log"
    assert continue_if_logs.first.completed?, "continue_if log should be completed"
  end

  def test_continue_if_in_complex_workflow
    unique_key = "continue_if_complex_#{Time.now.to_i}_#{rand(1000)}"

    ComplexWorkflowJob.perform_later(unique_key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: unique_key)
    assert_equal "idle", workflow.state, "workflow should be waiting at continue_if"
    assert_equal 1, workflow.context["step1_executed"], "step 1 should have executed"
    assert_nil workflow.context["step3_executed"], "step 3 should not have executed yet"

    # Make condition true and retry
    workflow.context[:condition_met] = true
    workflow.save!

    ComplexWorkflowJob.perform_later(unique_key)
    perform_all_jobs

    workflow.reload
    assert workflow.completed?, "workflow should be completed"
    assert_equal 1, workflow.context["step1_executed"], "step 1 should still be executed once"
    assert_equal 1, workflow.context["step3_executed"], "step 3 should now be executed"

    # Check execution log order - should be clean without retry logs
    step_names = workflow.execution_logs.order(:id).pluck(:step_name)
    expected_steps = [
      "durably_execute$step1",
      "continue_if$condition_met?",
      "durably_execute$step3",
      "$workflow_completion$"
    ]

    # Should have exactly the expected steps in order
    assert_equal expected_steps, step_names, "execution steps should be in correct order"
  end

  def test_multiple_continue_if_in_workflow
    unique_key = "continue_if_multiple_#{Time.now.to_i}_#{rand(1000)}"

    MultipleWaitsJob.perform_later(unique_key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: unique_key)
    assert_equal "idle", workflow.state, "workflow should be waiting at first continue_if"
    assert_equal 1, workflow.context["step1_count"], "step 1 should have executed"
    assert_nil workflow.context["step2_count"], "step 2 should not have executed yet"

    # Make first condition true
    workflow.context[:first_condition] = true
    workflow.save!

    MultipleWaitsJob.perform_later(unique_key)
    perform_all_jobs

    workflow.reload
    assert_equal "idle", workflow.state, "workflow should be waiting at second continue_if"
    assert_equal 1, workflow.context["step2_count"], "step 2 should now have executed"
    assert_nil workflow.context["step3_count"], "step 3 should not have executed yet"

    # Make second condition true
    workflow.context[:second_condition] = true
    workflow.save!

    MultipleWaitsJob.perform_later(unique_key)
    perform_all_jobs

    workflow.reload
    assert workflow.completed?, "workflow should be completed"
    assert_equal 1, workflow.context["step3_count"], "step 3 should now have executed"
  end

  def test_continue_if_with_custom_name
    unique_key = "continue_if_custom_name_#{Time.now.to_i}_#{rand(1000)}"

    ContinueIfCustomNameJob.perform_later(unique_key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: unique_key)
    assert workflow.completed?, "workflow should be completed"

    # Check execution logs with custom name
    continue_if_log = workflow.execution_logs.find { |log| log.step_name == "continue_if$custom_step_name" }
    assert continue_if_log, "should have continue_if execution log with custom name"
    assert continue_if_log.completed?, "continue_if log should be completed"
    assert_equal "condition_met?", continue_if_log.metadata["condition"], "should store original condition name"
    assert_equal "custom_step_name", continue_if_log.metadata["name"], "should store custom name"
    assert_equal true, continue_if_log.metadata["result"], "should record true result"
  end

  def test_continue_if_multiple_with_same_condition_different_names
    unique_key = "continue_if_multiple_names_#{Time.now.to_i}_#{rand(1000)}"

    MultipleNamesJob.perform_later(unique_key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: unique_key)
    assert_equal "idle", workflow.state, "workflow should be waiting at second continue_if"

    # Check that both continue_if steps were created with different names
    first_continue_if = workflow.execution_logs.find { |log| log.step_name == "continue_if$first_check" }
    second_continue_if = workflow.execution_logs.find { |log| log.step_name == "continue_if$second_check" }

    assert first_continue_if, "should have first continue_if log"
    assert second_continue_if, "should have second continue_if log"

    assert first_continue_if.completed?, "first continue_if should be completed"
    refute second_continue_if.completed?, "second continue_if should not be completed yet"

    # Should reference different condition methods with different custom names
    assert_equal "first_system_ready?", first_continue_if.metadata["condition"]
    assert_equal "second_system_ready?", second_continue_if.metadata["condition"]
    assert_equal "first_check", first_continue_if.metadata["name"]
    assert_equal "second_check", second_continue_if.metadata["name"]

    # Make second condition true and continue
    workflow.context[:second_ready] = true
    workflow.save!

    MultipleNamesJob.perform_later(unique_key)
    perform_all_jobs

    workflow.reload
    assert workflow.completed?, "workflow should be completed after second condition"

    second_continue_if.reload
    assert second_continue_if.completed?, "second continue_if should now be completed"

    # Check if final step was executed
    final_step_log = workflow.execution_logs.find { |log| log.step_name == "durably_execute$final_step" }
    assert final_step_log, "should have final step execution log"
    assert final_step_log.completed?, "final step should be completed"
  end

  private

  def clear_queues
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter.performed_jobs.clear
  end
end

# Test job classes

class ConditionAlreadyMetJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:execution_count, 0)
    continue_if :condition_met?
    context[:execution_count] = context.fetch(:execution_count, 0) + 1
  end

  private

  def condition_met?
    true # Always true
  end
end

class ConditionNotMetJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:check_count, 0)
    continue_if :condition_met?
    context[:after_continue] = true
  end

  private

  def condition_met?
    context[:check_count] = context.fetch(:check_count, 0) + 1
    # Return true if external flag is set
    context.fetch(:make_condition_true, false)
  end
end

class ConditionErrorJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    continue_if :error_condition?
    context[:should_not_reach] = true
  end

  private

  def error_condition?
    raise StandardError, "Simulated condition error"
  end
end

class IdempotentJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:check_count, 0)
    context.set_once(:post_continue_count, 0)

    continue_if :condition_met?

    context[:post_continue_count] = context.fetch(:post_continue_count, 0) + 1
  end

  private

  def condition_met?
    context[:check_count] = context.fetch(:check_count, 0) + 1
    context.fetch(:make_condition_true, false)
  end
end

class ComplexWorkflowJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    durably_execute :step1
    continue_if :condition_met?
    durably_execute :step3
  end

  private

  def step1
    context[:step1_executed] = context.fetch(:step1_executed, 0) + 1
  end

  def condition_met?
    context.fetch(:condition_met, false)
  end

  def step3
    context[:step3_executed] = context.fetch(:step3_executed, 0) + 1
  end
end

class MultipleWaitsJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    durably_execute :step1
    continue_if :first_condition_met?
    durably_execute :step2
    continue_if :second_condition_met?
    durably_execute :step3
  end

  private

  def step1
    context[:step1_count] = context.fetch(:step1_count, 0) + 1
  end

  def first_condition_met?
    context.fetch(:first_condition, false)
  end

  def step2
    context[:step2_count] = context.fetch(:step2_count, 0) + 1
  end

  def second_condition_met?
    context.fetch(:second_condition, false)
  end

  def step3
    context[:step3_count] = context.fetch(:step3_count, 0) + 1
  end
end

class ContinueIfCustomNameJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    continue_if :condition_met?, name: "custom_step_name"
  end

  private

  def condition_met?
    true # Always true
  end
end

class MultipleNamesJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    continue_if :first_system_ready?, name: "first_check"
    continue_if :second_system_ready?, name: "second_check"
    durably_execute :final_step
  end

  private

  def first_system_ready?
    true # Always ready
  end

  def second_system_ready?
    context.fetch(:second_ready, false)
  end

  def final_step
    context[:final_step_executed] = true
  end
end
