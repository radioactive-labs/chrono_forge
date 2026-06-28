require "test_helper"

# End-to-end: composite retry_policy arrays wired through the executor. Verifies
# per-error budgets accumulate independently (keyed by RetryPolicy#budget_key),
# fail-fast, subclass routing, the single-policy regression, and the
# workflow-level path.
class CompositeRetryPolicyIntegrationTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  RetryPolicy = ChronoForge::Executor::RetryPolicy

  class NetworkError < StandardError; end

  class FlakyNetworkError < NetworkError; end

  class RateLimitError < StandardError; end

  class DeclinedError < StandardError; end

  class WorkflowLevelError < StandardError; end

  def define_workflow(name, &block)
    test_class_name = "#{name}#{Time.now.to_i}_#{rand(100000)}"
    Object.const_set(test_class_name, Class.new(WorkflowJob) do
      prepend ChronoForge::Executor

      class_eval(&block)
    end)
    Object.const_get(test_class_name)
  end

  def test_each_error_type_has_an_independent_budget
    key = "composite_budgets_#{Time.now.to_i}_#{rand(10000)}"
    klass = define_workflow("CompositeBudgets") do
      define_method(:perform) do
        durably_execute :flaky, retry_policy: [
          RetryPolicy.new(retry_on: [NetworkError], max_attempts: 2, base: 0, cap: 0, jitter: false),
          RetryPolicy.new(retry_on: [RateLimitError], max_attempts: 3, base: 0, cap: 0, jitter: false)
        ]
      end
      # Interleave the two error types so neither hits its cap until the end:
      # call 1 -> Network, call 2 -> RateLimit, call 3 -> Network (Network's 2nd,
      # which reaches its cap of 2 and stops). RateLimit reached only 1 of its 3.
      define_method(:flaky) do
        n = (context[:n] = (context[:n] || 0) + 1)
        raise((n == 2) ? RateLimitError : NetworkError, "boom #{n}")
      end
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "durably_execute$flaky")
    assert_equal 3, log.attempts, "2 NetworkError + 1 RateLimitError attempts"
    assert_equal "failed", log.state, "NetworkError budget (2) exhausted"
    assert_equal({NetworkError.name => 2, RateLimitError.name => 1},
      log.metadata["retry_counts"], "budgets accumulate independently per declared error")
  end

  def test_subclass_draws_from_parent_policy_budget
    key = "composite_subclass_#{Time.now.to_i}_#{rand(10000)}"
    klass = define_workflow("CompositeSubclass") do
      define_method(:perform) do
        durably_execute :always_flaky, retry_policy: [
          RetryPolicy.new(retry_on: [NetworkError], max_attempts: 2, base: 0, cap: 0, jitter: false)
        ]
      end
      define_method(:always_flaky) { raise FlakyNetworkError, "boom" }
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "durably_execute$always_flaky")
    assert_equal 2, log.attempts, "subclass routes to NetworkError policy (budget 2)"
    assert_equal({NetworkError.name => 2}, log.metadata["retry_counts"],
      "subclass failures count against the parent policy's budget")
  end

  def test_unmatched_error_fails_fast
    key = "composite_unmatched_#{Time.now.to_i}_#{rand(10000)}"
    klass = define_workflow("CompositeUnmatched") do
      define_method(:perform) do
        durably_execute :raises_arg, retry_policy: [
          RetryPolicy.new(retry_on: [NetworkError], max_attempts: 5)
        ]
      end
      define_method(:raises_arg) { raise ArgumentError, "nope" }
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    log = workflow.execution_logs.find_by(step_name: "durably_execute$raises_arg")
    assert_equal 1, log.attempts, "no matching policy -> fail fast"
    assert_equal "failed", log.state
  end

  def test_single_policy_writes_no_retry_counts
    key = "single_no_counts_#{Time.now.to_i}_#{rand(10000)}"
    klass = define_workflow("SingleNoCounts") do
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
    assert_equal 2, log.attempts
    assert_nil log.metadata&.[]("retry_counts"), "single policy path writes no retry_counts"
  end

  def test_workflow_level_composite_default_routes_per_error
    key = "wf_composite_#{Time.now.to_i}_#{rand(10000)}"
    klass = define_workflow("WorkflowComposite") do
      retry_policy RetryPolicy.new(retry_on: [WorkflowLevelError], max_attempts: 2, base: 0, cap: 0, jitter: false),
        RetryPolicy.new(retry_on: nil, max_attempts: 5, base: 0, cap: 0, jitter: false)
      define_method(:perform) { raise WorkflowLevelError, "boom" }
    end

    klass.perform_later(key)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    assert workflow.failed?, "workflow fails once the WorkflowLevelError budget (2) is spent"
    assert_equal 2, workflow.error_logs.count, "retried per the WorkflowLevelError policy, not the catch-all"
  end
end
