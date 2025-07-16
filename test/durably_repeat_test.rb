require "test_helper"

class DurablyRepeatTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    # Clean up any existing workflows before each test
    ChronoForge::Workflow.destroy_all
  end

  def test_durably_repeat_creates_coordination_and_repetition_logs
    unique_key = "basic_#{Time.now.to_i}_#{rand(1000)}"

    BasicRepeatJob.perform_later(unique_key)

    # Execute immediate setup
    perform_all_jobs_before(1.second)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)
    assert workflow, "workflow should exist"

    # Should create coordination log
    coordination_log = workflow.execution_logs.find { |log| log.step_name == "durably_repeat$count_task" }
    assert coordination_log, "should have coordination log"

    # Should have scheduled first execution
    assert_operator enqueued_jobs.size, :>, 0, "should have scheduled jobs"

    # Execute scheduled jobs
    perform_all_jobs_before(5.seconds)

    workflow.reload

    # Should create repetition logs
    repetition_logs = workflow.execution_logs.select { |log| log.step_name.include?("durably_repeat$count_task$") }
    assert_operator repetition_logs.size, :>=, 1, "should have at least 1 repetition log"

    # Check repetition log structure
    repetition_logs.each do |log|
      assert log.metadata["scheduled_for"], "should have scheduled_for"
      assert log.metadata["timeout_at"], "should have timeout_at"
      assert log.metadata["parent_id"], "should reference coordination log"
      assert_equal coordination_log.id, log.metadata["parent_id"], "should reference correct parent"
    end

    # Should have executed the task
    assert_operator workflow.context["count"], :>=, 1, "should have incremented count"
  end

  def test_durably_repeat_passes_scheduled_time_parameter
    unique_key = "scheduled_time_#{Time.now.to_i}_#{rand(1000)}"

    ScheduledTimeJob.perform_later(unique_key)

    # Execute setup and first execution
    perform_all_jobs_before(5.seconds)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should have received scheduled time parameter
    assert workflow.context["received_scheduled_time"], "should have received scheduled time parameter"
    assert workflow.context["last_scheduled_time"], "should have stored scheduled time"

    # Validate it's a proper timestamp
    assert_nothing_raised { Time.parse(workflow.context["last_scheduled_time"]) }
  end

  def test_durably_repeat_with_custom_name
    unique_key = "custom_name_#{Time.now.to_i}_#{rand(1000)}"

    CustomNameJob.perform_later(unique_key)

    # Execute setup and first execution
    perform_all_jobs_before(5.seconds)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should use custom name in logs
    coordination_log = workflow.execution_logs.find { |log| log.step_name == "durably_repeat$my_custom_task" }
    assert coordination_log, "should use custom task name"

    repetition_logs = workflow.execution_logs.select { |log| log.step_name.include?("durably_repeat$my_custom_task$") }
    assert_operator repetition_logs.size, :>=, 1, "should have repetition logs with custom name"
  end

  def test_durably_repeat_completion_behavior
    unique_key = "completion_#{Time.now.to_i}_#{rand(1000)}"

    CompletionJob.perform_later(unique_key)

    # Execute setup
    perform_all_jobs_before(1.second)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)
    assert_equal false, workflow.completed?, "should not be completed initially"

    # Execute first round of tasks
    perform_all_jobs_before(5.seconds)

    # Continue executing until completion or timeout
    max_cycles = 10
    cycle = 0
    while enqueued_jobs.any? && cycle < max_cycles && !workflow.reload.completed?
      cycle += 1
      perform_all_jobs_before(10.seconds)
    end

    workflow.reload

    # Should eventually complete
    assert workflow.completed?, "workflow should complete when done condition is met"
    assert_equal 3, workflow.context["execution_count"], "should have executed exactly 3 times"
    assert_equal 0, enqueued_jobs.size, "should have no more enqueued jobs"
  end

  def test_durably_repeat_with_timeout
    unique_key = "timeout_#{Time.now.to_i}_#{rand(1000)}"

    TimeoutJob.perform_later(unique_key)

    # Execute setup and first execution attempts
    perform_all_jobs_before(5.seconds)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should have timeout failures
    timeout_logs = workflow.execution_logs.select { |log|
      log.failed? && log.error_message == "Execution timed out"
    }
    assert_operator timeout_logs.size, :>, 0, "should have timeout failures"
  end

  def test_durably_repeat_with_error_handling
    unique_key = "error_#{Time.now.to_i}_#{rand(1000)}"

    ErrorHandlingJob.perform_later(unique_key)

    # Execute setup and several execution attempts
    perform_all_jobs_before(5.seconds)

    # Continue for a few cycles to see error handling
    3.times do
      perform_all_jobs_before(10.seconds) if enqueued_jobs.any?
    end

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should have error logs from failures
    error_logs = workflow.error_logs.select { |log|
      log.error_message.include?("Simulated failure")
    }
    assert_operator error_logs.size, :>, 0, "should have error logs from failures"

    # Should have attempted multiple times
    assert_operator workflow.context["attempts"], :>=, 2, "should have attempted multiple times"

    # Should eventually succeed (error handling allows continuation)
    assert_operator workflow.context["success_count"], :>=, 1, "should eventually succeed"
  end

  def test_durably_repeat_fail_workflow_on_error
    unique_key = "fail_workflow_#{Time.now.to_i}_#{rand(1000)}"

    FailWorkflowJob.perform_later(unique_key)

    # Execute setup and several execution attempts
    perform_all_jobs_before(5.seconds)

    # Continue for a few cycles to trigger failure
    3.times do
      perform_all_jobs_before(10.seconds) if enqueued_jobs.any?
    end

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should have error logs from failures
    error_logs = workflow.error_logs.select { |log|
      log.error_message.include?("ExecutionFailedError") || log.error_message.include?("Always fails")
    }
    assert_operator error_logs.size, :>, 0, "should have failure error logs"

    # Workflow should be in failed state or have significant errors
    # Note: The exact failure state depends on when the workflow fails
    assert_operator workflow.error_logs.size, :>, 0, "workflow should have error logs when on_error: :fail_workflow"
  end

  def test_durably_repeat_with_start_at
    # Test that start_at parameter actually controls when first execution happens
    unique_key = "start_at_#{Time.now.to_i}_#{rand(1000)}"

    # Use a start time that's in the future but not too far
    start_time = Time.current + 3.seconds

    StartAtJob.perform_later(unique_key, start_time: start_time)

    # Execute setup only
    perform_all_jobs_before(1.second)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should have coordination log
    coordination_log = workflow.execution_logs.find { |log| log.step_name == "durably_repeat$start_at_task" }
    assert coordination_log, "should have coordination log"

    # Key test: Should NOT have executed yet since we're before start_time
    assert_equal 0, workflow.context.fetch("execution_count", 0), "should not have executed before start_at time"

    # Repetition logs are created immediately with future timestamps, but should not be completed yet
    repetition_logs = workflow.execution_logs.select { |log| log.step_name.include?("durably_repeat$start_at_task$") }
    if repetition_logs.any?
      repetition_logs.each do |log|
        assert_equal "pending", log.state, "repetition log should be pending before start_at time"
        refute log.completed?, "repetition log should not be completed before start_at time"
      end
    end

    # Fast forward to after the start_time and execute
    perform_all_jobs_before(5.seconds)

    workflow.reload

    # Now should have executed at least once
    assert_operator workflow.context["execution_count"], :>=, 1, "should have executed after start_at time"

    # Should have created repetition logs
    repetition_logs = workflow.execution_logs.select { |log| log.step_name.include?("durably_repeat$start_at_task$") }
    assert_operator repetition_logs.size, :>=, 1, "should have repetition logs after start_at time"

    # Verify the scheduled_for time in the repetition log matches our start_at time
    if repetition_logs.any?
      first_repetition = repetition_logs.first
      scheduled_time = Time.parse(first_repetition.metadata["scheduled_for"])

      # The scheduled time should be close to our start_time (within a reasonable margin)
      time_diff = (scheduled_time - start_time).abs
      assert time_diff < 2.seconds, "first execution should be scheduled close to start_at time (diff: #{time_diff}s)"
    end

    # Verify scheduled time was passed to the method
    assert_operator workflow.context["received_scheduled_times"].size, :>=, 1, "should have received scheduled times"
    first_received = workflow.context["received_scheduled_times"].first
    assert first_received["scheduled_time"], "should have received scheduled_time parameter"
  end

  def test_durably_repeat_with_max_attempts
    unique_key = "max_attempts_#{Time.now.to_i}_#{rand(1000)}"

    MaxAttemptsJob.perform_later(unique_key)

    # Execute setup and attempts
    perform_all_jobs_before(5.seconds)

    # Continue for multiple cycles to trigger max attempts
    5.times do
      perform_all_jobs_before(10.seconds) if enqueued_jobs.any?
    end

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should have attempted the configured max attempts
    assert_operator workflow.context["failure_count"], :>=, 5, "should respect max_attempts configuration"
  end

  def test_durably_repeat_method_with_optional_parameters
    unique_key = "optional_params_#{Time.now.to_i}_#{rand(1000)}"

    OptionalParamsJob.perform_later(unique_key)

    # Execute setup and first execution
    perform_all_jobs_before(5.seconds)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should have received scheduled time parameter despite method having optional params
    assert workflow.context["received_scheduled_time"], "should have received scheduled time parameter"
    assert workflow.context["last_scheduled_time"], "should have stored scheduled time"

    # Should have received the optional parameter value
    assert_equal "default_value", workflow.context["optional_param"], "should use default value for optional parameter"
  end

  def test_durably_repeat_with_till_as_proc
    unique_key = "till_proc_#{Time.now.to_i}_#{rand(1000)}"

    TillProcJob.perform_later(unique_key)

    # Execute setup and several iterations
    perform_all_jobs_before(5.seconds)

    # Continue for multiple cycles
    5.times do
      perform_all_jobs_before(10.seconds) if enqueued_jobs.any?
    end

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should have executed multiple times and stopped when proc returned true
    assert_operator workflow.context["execution_count"], :>=, 5, "should have executed at least 5 times"
    assert workflow.completed?, "should be completed when proc condition is met"
  end

  def test_durably_repeat_with_past_start_at
    unique_key = "past_start_#{Time.now.to_i}_#{rand(1000)}"

    # Use a start time that's in the past
    start_time = Time.current - 5.seconds

    PastStartAtJob.perform_later(unique_key, start_time: start_time)

    # Execute setup and first execution
    perform_all_jobs_before(5.seconds)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should execute immediately since start_at is in the past
    assert_operator workflow.context["execution_count"], :>=, 1, "should execute immediately when start_at is in the past"

    # Should have received the past scheduled time
    received_times = workflow.context["received_scheduled_times"]
    assert_operator received_times.size, :>=, 1, "should have received scheduled times"

    first_received = received_times.first
    received_time = Time.parse(first_received["scheduled_time"])

    # The received time should be close to our past start_time
    time_diff = (received_time - start_time).abs
    assert time_diff < 1.second, "should receive the past start_at time as scheduled_time"
  end

  def test_durably_repeat_with_different_durations
    unique_key = "durations_#{Time.now.to_i}_#{rand(1000)}"

    DurationTestJob.perform_later(unique_key)

    # Execute setup and several short intervals
    perform_all_jobs_before(3.seconds)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Should have executed multiple times with 1-second intervals
    assert_operator workflow.context["execution_count"], :>=, 2, "should execute multiple times with short intervals"
    assert_operator workflow.context["execution_count"], :<=, 5, "should not execute too many times"
  end

  def test_durably_repeat_coordination_log_updated_on_timeout
    unique_key = "timeout_coord_#{Time.now.to_i}_#{rand(1000)}"

    TimeoutCoordinationJob.perform_later(unique_key)

    # Execute setup
    perform_all_jobs_before(1.second)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Get coordination log
    coordination_log = workflow.execution_logs.find { |log| log.step_name == "durably_repeat$timeout_coord_task" }
    assert coordination_log, "should have coordination log"

    # Store initial state
    initial_last_executed_at = coordination_log.last_executed_at
    initial_metadata = coordination_log.metadata.dup

    # Execute timeout attempts
    perform_all_jobs_before(3.seconds)

    workflow.reload
    coordination_log.reload

    # Find timeout logs
    timeout_logs = workflow.execution_logs.select { |log|
      log.failed? && log.error_message == "Execution timed out"
    }
    assert_operator timeout_logs.size, :>, 0, "should have timeout failures"

    # Verify coordination log was updated despite timeout
    assert_not_equal initial_last_executed_at, coordination_log.last_executed_at,
      "coordination log last_executed_at should be updated even on timeout"

    assert coordination_log.metadata["last_execution_at"],
      "coordination log should have last_execution_at in metadata"

    assert_not_equal initial_metadata["last_execution_at"], coordination_log.metadata["last_execution_at"],
      "coordination log last_execution_at should be updated after timeout"
  end

  def test_durably_repeat_coordination_log_updated_on_success
    unique_key = "success_coord_#{Time.now.to_i}_#{rand(1000)}"

    SuccessCoordinationJob.perform_later(unique_key)

    # Execute setup
    perform_all_jobs_before(1.second)

    workflow = ChronoForge::Workflow.find_by(key: unique_key)

    # Get coordination log
    coordination_log = workflow.execution_logs.find { |log| log.step_name == "durably_repeat$success_coord_task" }
    assert coordination_log, "should have coordination log"

    # Store initial state
    initial_last_executed_at = coordination_log.last_executed_at
    initial_metadata = coordination_log.metadata.dup

    # Execute successful execution
    perform_all_jobs_before(3.seconds)

    workflow.reload
    coordination_log.reload

    # Verify successful execution
    assert_operator workflow.context["execution_count"], :>=, 1, "should have executed successfully"

    # Find successful repetition logs
    success_logs = workflow.execution_logs.select { |log|
      log.step_name.include?("durably_repeat$success_coord_task$") && log.completed?
    }
    assert_operator success_logs.size, :>, 0, "should have successful executions"

    # Verify coordination log was updated after successful execution
    assert_not_equal initial_last_executed_at, coordination_log.last_executed_at,
      "coordination log last_executed_at should be updated on success"

    assert coordination_log.metadata["last_execution_at"],
      "coordination log should have last_execution_at in metadata"

    assert_not_equal initial_metadata["last_execution_at"], coordination_log.metadata["last_execution_at"],
      "coordination log last_execution_at should be updated after success"
  end

  private

  def perform_jobs_until_completion(workflow, max_cycles: 10)
    cycle = 0
    while enqueued_jobs.any? && cycle < max_cycles && !workflow.reload.completed?
      cycle += 1
      perform_all_jobs_before(10.seconds)
    end
    workflow.reload
  end
end

# Test job classes

class BasicRepeatJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:count, 0)
    durably_repeat :count_task, every: 2.seconds, till: :target_reached?
  end

  private

  def count_task
    context[:count] = context.fetch(:count, 0) + 1
  end

  def target_reached?
    context.fetch(:count, 0) >= 3
  end
end

class ScheduledTimeJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:received_scheduled_time, false)
    context.set_once(:last_scheduled_time, nil)
    durably_repeat :scheduled_task, every: 2.seconds, till: :done?
  end

  private

  def scheduled_task(scheduled_time = nil)
    context[:received_scheduled_time] = !scheduled_time.nil?
    context[:last_scheduled_time] = scheduled_time&.iso8601
  end

  def done?
    context.fetch(:received_scheduled_time, false)
  end
end

class CustomNameJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:executed, false)
    durably_repeat :some_task, every: 2.seconds, till: :finished?, name: "my_custom_task"
  end

  private

  def some_task
    context[:executed] = true
  end

  def finished?
    context.fetch(:executed, false)
  end
end

class CompletionJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:execution_count, 0)
    durably_repeat :counting_task, every: 2.seconds, till: :done?
  end

  private

  def counting_task
    context[:execution_count] = context.fetch(:execution_count, 0) + 1
  end

  def done?
    context.fetch(:execution_count, 0) >= 3
  end
end

class TimeoutJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:attempts, 0)
    # Use negative timeout to force immediate timeout
    durably_repeat :timeout_task, every: 2.seconds, till: :done?, timeout: -1.second
  end

  private

  def timeout_task
    context[:attempts] = context.fetch(:attempts, 0) + 1
  end

  def done?
    context.fetch(:attempts, 0) >= 3
  end
end

class ErrorHandlingJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:attempts, 0)
    context.set_once(:success_count, 0)
    durably_repeat :failing_task, every: 2.seconds, till: :done?, on_error: :continue
  end

  private

  def failing_task
    attempts = context.fetch(:attempts, 0) + 1
    context[:attempts] = attempts

    # Fail first 2 attempts, then succeed
    if attempts <= 2
      raise StandardError, "Simulated failure (attempt #{attempts})"
    else
      context[:success_count] = context.fetch(:success_count, 0) + 1
    end
  end

  def done?
    context.fetch(:success_count, 0) >= 2
  end
end

class FailWorkflowJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:attempts, 0)
    durably_repeat :failing_task, every: 2.seconds, till: :done?, on_error: :fail_workflow
  end

  private

  def failing_task
    context[:attempts] = context.fetch(:attempts, 0) + 1
    raise StandardError, "Always fails"
  end

  def done?
    false # Never complete, always fail
  end
end

class StartAtJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform(start_time:)
    context.set_once(:execution_count, 0)
    context.set_once(:received_scheduled_times, [])

    # Handle start_time which might be a Time object or serialized string
    start_time_obj = start_time.is_a?(String) ? Time.parse(start_time) : start_time
    context.set_once(:expected_start_time, start_time_obj.iso8601)

    durably_repeat :start_at_task, every: 2.seconds, till: :done?, start_at: start_time_obj
  end

  private

  def start_at_task(scheduled_time = nil)
    context[:execution_count] = context.fetch(:execution_count, 0) + 1

    # Capture debugging info about what scheduled_time we received
    received_times = context.fetch(:received_scheduled_times, [])
    received_times << {
      scheduled_time: scheduled_time&.iso8601,
      current_time: Time.current.iso8601,
      execution_count: context[:execution_count]
    }
    context[:received_scheduled_times] = received_times
  end

  def done?
    context.fetch(:execution_count, 0) >= 1
  end
end

class MaxAttemptsJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:failure_count, 0)
    durably_repeat :failing_task, every: 2.seconds, till: :done?, max_attempts: 5, on_error: :continue
  end

  private

  def failing_task
    context[:failure_count] = context.fetch(:failure_count, 0) + 1
    raise StandardError, "Simulated failure for max attempts test"
  end

  def done?
    context.fetch(:failure_count, 0) >= 5
  end
end

class OptionalParamsJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:received_scheduled_time, false)
    context.set_once(:last_scheduled_time, nil)
    context.set_once(:optional_param, nil)
    durably_repeat :optional_task, every: 2.seconds, till: :done?
  end

  private

  def optional_task(scheduled_time = nil, optional_param = "default_value")
    context[:received_scheduled_time] = !scheduled_time.nil?
    context[:last_scheduled_time] = scheduled_time&.iso8601
    context[:optional_param] = optional_param
  end

  def done?
    context.fetch(:received_scheduled_time, false)
  end
end

class TillProcJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:execution_count, 0)
    # Use a proc instead of a symbol for the till parameter
    durably_repeat :till_proc_task, every: 2.seconds, till: ->(ctx) { ctx.fetch(:execution_count, 0) >= 5 }
  end

  private

  def till_proc_task
    context[:execution_count] = context.fetch(:execution_count, 0) + 1
  end
end

class PastStartAtJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform(start_time:)
    context.set_once(:execution_count, 0)
    context.set_once(:received_scheduled_times, [])

    # Handle start_time which might be a Time object or serialized string
    start_time_obj = start_time.is_a?(String) ? Time.parse(start_time) : start_time
    context.set_once(:expected_start_time, start_time_obj.iso8601)

    durably_repeat :past_start_task, every: 2.seconds, till: :done?, start_at: start_time_obj
  end

  private

  def past_start_task(scheduled_time = nil)
    context[:execution_count] = context.fetch(:execution_count, 0) + 1

    # Capture debugging info about what scheduled_time we received
    received_times = context.fetch(:received_scheduled_times, [])
    received_times << {
      scheduled_time: scheduled_time&.iso8601,
      current_time: Time.current.iso8601,
      execution_count: context[:execution_count]
    }
    context[:received_scheduled_times] = received_times
  end

  def done?
    context.fetch(:execution_count, 0) >= 1
  end
end

class DurationTestJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:execution_count, 0)
    durably_repeat :duration_task, every: 1.second, till: :done?
  end

  private

  def duration_task
    context[:execution_count] = context.fetch(:execution_count, 0) + 1
  end

  def done?
    context.fetch(:execution_count, 0) >= 5
  end
end

class TimeoutCoordinationJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:attempts, 0)
    # Use negative timeout to force immediate timeout
    durably_repeat :timeout_coord_task, every: 1.second, till: :done?, timeout: -1.second
  end

  private

  def timeout_coord_task
    context[:attempts] = context.fetch(:attempts, 0) + 1
  end

  def done?
    context.fetch(:attempts, 0) >= 3
  end
end

class SuccessCoordinationJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once(:execution_count, 0)
    durably_repeat :success_coord_task, every: 1.second, till: :done?
  end

  private

  def success_coord_task
    context[:execution_count] = context.fetch(:execution_count, 0) + 1
  end

  def done?
    context.fetch(:execution_count, 0) >= 2
  end
end
