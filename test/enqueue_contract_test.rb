require "test_helper"

# Public enqueue contract for Executor-prepended jobs: perform_now/perform_later
# accept exactly one positional (`key`) plus keywords, reject ChronoForge's
# reserved internal kwargs, and pass `options`/user kwargs through to the
# workflow record. retry_now/retry_later route past the guard via `.set(...)`.
class EnqueueContractTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  class ContractJob < WorkflowJob
    prepend ChronoForge::Executor
    def perform(foo: nil)
      context[:foo] = foo
    end
  end

  # --- reserved-key rejection ------------------------------------------------

  def test_perform_later_rejects_reserved_keys
    ChronoForge::Executor::RESERVED_KWARGS.each do |reserved|
      err = nil
      # assert_raises must sit inside the block-based assertion: Rails wraps the
      # block in assert_nothing_raised, which would otherwise rewrap our error.
      assert_no_enqueued_jobs do
        err = assert_raises(ArgumentError) do
          ContractJob.perform_later("k-#{reserved}", reserved => 1)
        end
      end
      assert_match(/reserved/, err.message)
      assert_match(reserved.to_s, err.message)
    end
  end

  def test_perform_now_rejects_reserved_keys
    ChronoForge::Executor::RESERVED_KWARGS.each do |reserved|
      err = assert_raises(ArgumentError) do
        ContractJob.perform_now("k-#{reserved}", reserved => 1)
      end
      assert_match(/reserved/, err.message)
    end
  end

  # --- keywords-only contract ------------------------------------------------

  def test_perform_later_rejects_extra_positional
    err = nil
    assert_no_enqueued_jobs do
      err = assert_raises(ArgumentError) { ContractJob.perform_later("k", 99) }
    end
    assert_match(/keyword/, err.message)
  end

  def test_perform_now_rejects_extra_positional
    err = assert_raises(ArgumentError) { ContractJob.perform_now("k", 99) }
    assert_match(/keyword/, err.message)
  end

  def test_non_string_key_still_rejected
    assert_raises(ArgumentError) { ContractJob.perform_later(123) }
    assert_raises(ArgumentError) { ContractJob.perform_now(123) }
  end

  # --- public kwargs pass through --------------------------------------------

  def test_options_and_user_kwargs_pass_through
    key = "contract-#{SecureRandom.hex(4)}"
    ContractJob.perform_later(key, foo: "bar", options: {plan: "pro"})
    perform_all_jobs

    wf = ChronoForge::Workflow.find_by(key: key)
    assert_equal({"plan" => "pro"}, wf.options)
    assert_equal "bar", wf.kwargs["foo"]
    assert_equal "bar", wf.context["foo"]
  end

  # --- retry helpers route past the guard ------------------------------------

  def test_retry_helpers_reject_reserved_keys_from_caller
    assert_raises(ArgumentError) { ContractJob.retry_now("k", attempt: 1) }
    assert_raises(ArgumentError) { ContractJob.retry_later("k", attempt: 1) }
  end
end
