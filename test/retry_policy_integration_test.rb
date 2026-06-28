require "test_helper"

# Exercises RetryPolicy wired through the executor: per-call `retry:` overrides,
# the class-level `retry_policy` default, and wait_until's opt-in error retries.
class RetryPolicyIntegrationTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  RetryPolicy = ChronoForge::Executor::RetryPolicy

  class TransientError < StandardError; end

  def test_durably_execute_honors_per_call_retry_override
    key = "per_call_override_#{Time.now.to_i}"
    klass = define_workflow("PerCallOverride") do
      define_method(:perform) do
        durably_execute :always_fails,
          retry_policy: RetryPolicy.new(max_attempts: 2, base: 0, cap: 0, jitter: false)
      end
      define_method(:always_fails) { raise "boom" }
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "durably_execute$always_fails")
    assert_equal 2, log.attempts, "should stop at the per-call cap of 2"
    assert_equal "failed", log.state
    refute workflow.completed?
  end

  def test_class_level_retry_policy_default_applies_to_steps
    key = "class_default_#{Time.now.to_i}"
    klass = define_workflow("ClassDefault") do
      retry_policy max_attempts: 2, base: 0, cap: 0, jitter: false
      define_method(:perform) { durably_execute :always_fails }
      define_method(:always_fails) { raise "boom" }
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "durably_execute$always_fails")
    assert_equal 2, log.attempts, "class-level default cap of 2 should apply"
  end

  def test_wait_until_does_not_retry_condition_errors_by_default
    key = "wait_no_retry_#{Time.now.to_i}"
    klass = define_workflow("WaitNoRetry") do
      define_method(:perform) do
        wait_until :raises_transient, timeout: 1.second, check_interval: 0.1.second
      end
      define_method(:raises_transient) { raise TransientError, "not ready" }
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "wait_until$raises_transient")
    assert_equal "failed", log.state, "an unlisted condition error fails fast"
    assert_equal 1, log.attempts, "no retry of the condition error by default"
  end

  def test_wait_until_retries_listed_condition_error_then_succeeds
    key = "wait_retry_#{Time.now.to_i}"
    klass = define_workflow("WaitRetry") do
      define_method(:perform) do
        wait_until :ready_after_one_error,
          timeout: 1.hour,
          check_interval: 0.1.second,
          retry_policy: RetryPolicy.new(max_attempts: 5, base: 0, cap: 0, jitter: false, retry_on: [TransientError])
      end
      define_method(:ready_after_one_error) do
        context[:checks] = (context[:checks] || 0) + 1
        raise TransientError, "warming up" if context[:checks] < 2
        true
      end
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "wait_until$ready_after_one_error")
    assert_equal "completed", log.state, "listed error retried, then condition met"
  end

  private

  def define_workflow(name, &block)
    test_class_name = "#{name}#{Time.now.to_i}_#{rand(100000)}"
    Object.const_set(test_class_name, Class.new(WorkflowJob) do
      prepend ChronoForge::Executor

      class_eval(&block)
    end)
    Object.const_get(test_class_name)
  end
end
