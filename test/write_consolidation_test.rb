require "test_helper"

class NoopCompletionWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    # No durable steps: the only execution log is the completion marker.
  end
end

class WriteConsolidationTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def test_completion_log_written_with_single_update
    updates = count_execution_log_updates do
      NoopCompletionWorkflow.perform_later("noop_#{Time.now.to_i}")
      perform_all_jobs
    end

    workflow = ChronoForge::Workflow.last
    assert workflow.completed?, "workflow should complete"

    completion = workflow.execution_logs.find_by(step_name: "$workflow_completion$")
    assert completion.completed?, "completion log should be marked completed"
    assert_equal 1, completion.attempts, "completion attempt should be recorded"
    assert completion.completed_at, "completion timestamp should be set"

    # The attempt count, last_executed_at, state and completed_at can all be set
    # in one UPDATE rather than a separate attempt-bump followed by a state write.
    assert_equal 1, updates,
      "completion log should be persisted with a single UPDATE, got #{updates}"
  end

  private

  def count_execution_log_updates
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      count += 1 if /UPDATE ["`]?chrono_forge_execution_logs/i.match?(args.last[:sql].to_s)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
