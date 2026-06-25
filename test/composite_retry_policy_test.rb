require "test_helper"

class CompositeRetryPolicyTest < ActiveSupport::TestCase
  RetryPolicy = ChronoForge::Executor::RetryPolicy
  CompositeRetryPolicy = ChronoForge::Executor::CompositeRetryPolicy

  class NetworkError < StandardError; end

  class FlakyNetworkError < NetworkError; end

  class RateLimitError < StandardError; end

  class DeclinedError < StandardError; end

  def composite
    CompositeRetryPolicy.new([
      RetryPolicy.new(retry_on: [NetworkError], max_attempts: 5, base: 1, cap: 1000, jitter: false),
      RetryPolicy.new(retry_on: [RateLimitError], max_attempts: 10, base: 2, cap: 1000, jitter: false),
      RetryPolicy.new(retry_on: [DeclinedError], max_attempts: 1)
    ])
  end

  def test_empty_policy_list_raises
    assert_raises(ArgumentError) { CompositeRetryPolicy.new([]) }
  end

  def test_policy_for_first_match_wins
    catch_all = RetryPolicy.new(retry_on: nil)
    c = CompositeRetryPolicy.new([RetryPolicy.new(retry_on: [NetworkError]), catch_all])
    assert_equal NetworkError, c.policy_for(NetworkError.new).retry_on.first
    assert_same catch_all, c.policy_for(RateLimitError.new), "falls through to catch-all"
  end

  def test_policy_for_subclass_routes_to_parent_policy
    assert_equal [NetworkError], composite.policy_for(FlakyNetworkError.new).retry_on
  end

  def test_policy_for_no_match_returns_nil
    assert_nil composite.policy_for(ArgumentError.new)
  end

  def test_retry_backoff_yields_matched_budget_key_and_uses_count
    yielded = nil
    backoff = composite.retry_backoff(RateLimitError.new, attempts: 99) do |key|
      yielded = key
      3 # pretend this is the 3rd rate-limit failure
    end
    assert_equal RateLimitError.name, yielded, "yields the matched policy's declared-error key"
    # base 2, exponent (3-1)=2 -> 2 * 2**2 = 8
    assert_in_delta 8.0, backoff.to_f, 0.001, "backoff uses the yielded count, not attempts:"
  end

  def test_retry_backoff_without_block_uses_attempts
    backoff = composite.retry_backoff(NetworkError.new, attempts: 1)
    assert_in_delta 1.0, backoff.to_f, 0.001
  end

  def test_retry_backoff_stops_at_matched_policy_cap
    # DeclinedError policy max_attempts: 1 -> first failure (count 1) does not retry
    assert_nil composite.retry_backoff(DeclinedError.new, attempts: 1) { |_idx| 1 }
  end

  def test_retry_backoff_no_match_returns_nil
    assert_nil composite.retry_backoff(ArgumentError.new, attempts: 1) { |_idx| 1 }
  end

  def test_max_attempts_is_coarsest_bound
    assert_equal 10, composite.max_attempts
  end

  def test_max_attempts_nil_when_any_unbounded
    c = CompositeRetryPolicy.new([
      RetryPolicy.new(max_attempts: 3),
      RetryPolicy.new(max_attempts: nil)
    ])
    assert_nil c.max_attempts
  end
end
