require "test_helper"

# Error logs should be (a) free of the redundant ExecutionFailedError wrapper a
# step already logged its cause for, and (b) attributable to the step + attempt
# they came from, so they can be ordered and correlated when tailing a workflow.
class ErrorLogCorrelationTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  class FailingStepWorkflow < WorkflowJob
    prepend ChronoForge::Executor
    def perform
      durably_execute :always_fails
    end

    def always_fails
      raise "boom from step"
    end
  end

  class TimeoutWorkflow < WorkflowJob
    prepend ChronoForge::Executor
    def perform
      wait_until :never?, timeout: -1.second, check_interval: 1.second
    end

    def never?
      false
    end
  end

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def test_failed_step_logs_one_error_per_attempt_with_no_wrapper
    FailingStepWorkflow.perform_later("fail-#{SecureRandom.hex(4)}")
    perform_all_jobs
    wf = ChronoForge::Workflow.last

    assert wf.stalled?, "workflow should stall after the step gives up"

    # No ExecutionFailedError wrapper duplicate — only the real error, once per attempt.
    assert_equal ["RuntimeError"], wf.error_logs.pluck(:error_class).uniq,
      "the control-flow ExecutionFailedError wrapper must not be logged"
    assert_equal 3, wf.error_logs.count, "one error per attempt, no duplicate wrapper"

    # Each error is attributable to its step and attempt.
    logs = wf.error_logs.order(:id)
    assert_equal ["durably_execute$always_fails"], logs.map(&:step_name).uniq
    assert_equal [1, 2, 3], logs.map(&:attempt)
  end

  def test_wait_until_timeout_is_logged_at_the_step
    TimeoutWorkflow.perform_later("timeout-#{SecureRandom.hex(4)}")
    perform_all_jobs
    wf = ChronoForge::Workflow.last

    err = wf.error_logs.find_by(error_class: "ChronoForge::Executor::WaitConditionNotMet")
    assert err, "a wait_until timeout should still be recorded as an error"
    assert_equal "wait_until$never?", err.step_name
  end
end
