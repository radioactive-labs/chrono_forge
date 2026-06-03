require "test_helper"

class RetryPolicyTest < ActiveSupport::TestCase
  RetryPolicy = ChronoForge::Executor::RetryPolicy

  class CustomError < StandardError; end

  class SubError < CustomError; end

  class UnrelatedError < StandardError; end

  # --- retryable?: attempt count ---

  def test_retryable_within_max_attempts
    policy = RetryPolicy.new(max_attempts: 3)
    assert policy.retryable?(StandardError.new, 1), "1st attempt is below cap"
    assert policy.retryable?(StandardError.new, 2), "2nd attempt is below cap"
  end

  def test_not_retryable_at_max_attempts
    policy = RetryPolicy.new(max_attempts: 3)
    refute policy.retryable?(StandardError.new, 3), "3rd attempt reaches the cap"
    refute policy.retryable?(StandardError.new, 4), "beyond the cap"
  end

  def test_nil_max_attempts_never_count_caps
    policy = RetryPolicy.new(max_attempts: nil)
    assert policy.retryable?(StandardError.new, 1)
    assert policy.retryable?(StandardError.new, 1_000_000)
  end

  # --- retryable?: error class predicate ---

  def test_retry_on_nil_retries_any_standard_error
    policy = RetryPolicy.new(max_attempts: 5, retry_on: nil)
    assert policy.retryable?(CustomError.new, 1)
    assert policy.retryable?(UnrelatedError.new, 1)
  end

  def test_retry_on_list_retries_only_listed_classes
    policy = RetryPolicy.new(max_attempts: 5, retry_on: [CustomError])
    assert policy.retryable?(CustomError.new, 1), "listed class retries"
    assert policy.retryable?(SubError.new, 1), "subclass of a listed class retries"
    refute policy.retryable?(UnrelatedError.new, 1), "unlisted class does not retry"
  end

  def test_empty_retry_on_retries_nothing
    policy = RetryPolicy.new(max_attempts: 5, retry_on: [])
    refute policy.retryable?(CustomError.new, 1)
    refute policy.retryable?(StandardError.new, 1)
  end

  def test_count_and_error_predicate_are_combined
    policy = RetryPolicy.new(max_attempts: 2, retry_on: [CustomError])
    refute policy.retryable?(CustomError.new, 2), "right error but count exhausted"
    refute policy.retryable?(UnrelatedError.new, 1), "right count but wrong error"
    assert policy.retryable?(CustomError.new, 1), "right error and count"
  end

  # --- backoff_for: curve ---

  def test_backoff_grows_exponentially_without_jitter
    policy = RetryPolicy.new(base: 1, cap: 1000, jitter: false)
    assert_in_delta 1.0, policy.backoff_for(1).to_f, 0.001, "first retry = base"
    assert_in_delta 2.0, policy.backoff_for(2).to_f, 0.001
    assert_in_delta 4.0, policy.backoff_for(3).to_f, 0.001
    assert_in_delta 8.0, policy.backoff_for(4).to_f, 0.001
  end

  def test_backoff_respects_cap_without_jitter
    policy = RetryPolicy.new(base: 1, cap: 30, jitter: false)
    assert_in_delta 30.0, policy.backoff_for(10).to_f, 0.001, "clamped to cap"
    assert_in_delta 30.0, policy.backoff_for(100).to_f, 0.001
  end

  def test_backoff_honors_base_without_jitter
    policy = RetryPolicy.new(base: 5, cap: 1000, jitter: false)
    assert_in_delta 5.0, policy.backoff_for(1).to_f, 0.001
    assert_in_delta 10.0, policy.backoff_for(2).to_f, 0.001
  end

  def test_backoff_with_jitter_stays_within_equal_jitter_band
    policy = RetryPolicy.new(base: 1, cap: 1000, jitter: true)
    # equal jitter: result in [d/2, d] for the undisturbed delay d
    50.times do
      d = 8.0 # backoff_for(4) undisturbed
      val = policy.backoff_for(4).to_f
      assert_operator val, :>=, d / 2, "jittered value not below half"
      assert_operator val, :<=, d, "jittered value not above full"
    end
  end

  # --- presets ---

  def test_step_default_preset
    policy = RetryPolicy.step_default
    assert_equal 3, policy.max_attempts
    assert_nil policy.retry_on, "steps retry any StandardError by default"
    assert_in_delta 30.0, policy.cap.to_f, 0.001
  end

  def test_workflow_default_preset
    policy = RetryPolicy.workflow_default
    assert_equal 10, policy.max_attempts, "tolerant window up to ~8.5 min for transient infra errors"
    assert_nil policy.retry_on
    assert_in_delta 600.0, policy.cap.to_f, 0.001, "10 min per-delay ceiling"
  end

  def test_wait_default_preset_retries_nothing
    policy = RetryPolicy.wait_default
    assert_equal [], policy.retry_on, "condition errors are not retried unless opted in"
  end
end
