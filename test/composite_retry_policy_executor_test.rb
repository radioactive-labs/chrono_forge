require "test_helper"

# White-box tests for the executor's composite plumbing: policy coercion, the
# class-level DSL overload, and the metadata-backed per-error counter.
class CompositeRetryPolicyExecutorTest < ActiveSupport::TestCase
  RetryPolicy = ChronoForge::Executor::RetryPolicy
  CompositeRetryPolicy = ChronoForge::Executor::CompositeRetryPolicy

  # A bare object mixing in the executor so we can call its private helpers.
  def executor
    Class.new do
      prepend ChronoForge::Executor
    end.allocate
  end

  def test_coerce_policy_wraps_array
    coerced = executor.send(:coerce_policy, [RetryPolicy.new, RetryPolicy.new])
    assert_instance_of CompositeRetryPolicy, coerced
    assert_equal 2, coerced.policies.size
  end

  def test_coerce_policy_passes_through_single_and_composite
    single = RetryPolicy.new
    assert_same single, executor.send(:coerce_policy, single)
    composite = CompositeRetryPolicy.new([RetryPolicy.new])
    assert_same composite, executor.send(:coerce_policy, composite)
  end

  def test_coerce_policy_nil
    assert_nil executor.send(:coerce_policy, nil)
  end

  def test_class_dsl_positional_sets_composite_default
    klass = Class.new do
      prepend ChronoForge::Executor

      retry_policy RetryPolicy.new(retry_on: [ArgumentError]), RetryPolicy.new(retry_on: nil)
    end
    assert_instance_of CompositeRetryPolicy, klass.default_retry_policy
  end

  def test_class_dsl_kwargs_sets_single_default
    klass = Class.new do
      prepend ChronoForge::Executor

      retry_policy max_attempts: 7
    end
    assert_instance_of RetryPolicy, klass.default_retry_policy
    assert_equal 7, klass.default_retry_policy.max_attempts
  end

  def test_class_dsl_mixing_positional_and_kwargs_raises
    assert_raises(ArgumentError) do
      Class.new do
        prepend ChronoForge::Executor

        retry_policy RetryPolicy.new, max_attempts: 3
      end
    end
  end

  def test_bump_retry_count_increments_and_persists
    workflow = ChronoForge::Workflow.create!(job_class: "X", key: "bump-#{Time.now.to_i}-#{rand(10000)}")
    log = ChronoForge::ExecutionLog.create!(workflow: workflow, step_name: "s", metadata: {})

    assert_equal 1, executor.send(:bump_retry_count!, log, "NetworkError")
    assert_equal 2, executor.send(:bump_retry_count!, log, "NetworkError")
    assert_equal 1, executor.send(:bump_retry_count!, log, "RateLimitError"), "each policy key is independent"

    log.reload
    assert_equal({"NetworkError" => 2, "RateLimitError" => 1}, log.metadata["retry_counts"])
  end

  def test_bump_retry_count_handles_nil_metadata
    workflow = ChronoForge::Workflow.create!(job_class: "X", key: "bumpnil-#{Time.now.to_i}-#{rand(10000)}")
    log = ChronoForge::ExecutionLog.create!(workflow: workflow, step_name: "s", metadata: nil)
    assert_equal 1, executor.send(:bump_retry_count!, log, "NetworkError")
  end
end
