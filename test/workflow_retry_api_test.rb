require "test_helper"

# Record-level retry: re-run a failed/stalled workflow straight from its
# ChronoForge::Workflow record, without constantizing the job class or
# re-passing the key. retry_later must validate up front and raise immediately
# (not enqueue a doomed job) when the workflow isn't retryable.
class WorkflowRetryApiTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  NotRetryable = ChronoForge::Executor::WorkflowNotRetryableError

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def make_record(state)
    ChronoForge::Workflow.create!(
      key: "rec-#{SecureRandom.hex(4)}",
      job_class: "WorkflowRetryApiTest::RetryRecordWorkflow",
      kwargs: {}, options: {}, context: {}, state: state
    )
  end

  def test_retryable_predicate
    assert make_record(:failed).retryable?
    assert make_record(:stalled).retryable?
    refute make_record(:completed).retryable?
    refute make_record(:running).retryable?
    refute make_record(:idle).retryable?
  end

  def test_retry_later_raises_immediately_and_enqueues_nothing_when_not_retryable
    wf = make_record(:completed)
    assert_no_enqueued_jobs do
      assert_raises(NotRetryable) { wf.retry_later }
    end
  end

  def test_retry_now_raises_immediately_when_not_retryable
    wf = make_record(:running)
    assert_raises(NotRetryable) { wf.retry_now }
  end

  class RetryRecordWorkflow < WorkflowJob
    prepend ChronoForge::Executor

    def perform
      raise "fail until recovered" unless context.key?(:recovered)
      context[:done] = true
    end
  end

  def test_record_retry_later_reruns_a_failed_workflow
    key = "rec-int-#{SecureRandom.hex(4)}"
    RetryRecordWorkflow.perform_later(key)
    perform_all_jobs

    wf = ChronoForge::Workflow.find_by(key: key)
    assert_equal "failed", wf.state, "precondition: workflow has failed"

    wf.context[:recovered] = true
    wf.save!

    wf.retry_later
    perform_all_jobs

    wf.reload
    assert_equal "completed", wf.state, "record-level retry should re-run and complete the workflow"
    assert_equal true, wf.context["done"]
  end
end
