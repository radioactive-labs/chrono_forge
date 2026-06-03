require "test_helper"

# Regression tests for the query shape of the replay loop.
#
# A replay-based engine re-runs the whole workflow body on every resume. Each
# durable step looks up its ExecutionLog and the run looks up its Workflow row.
# Without SELECT-first lookups, an already-persisted row issues an INSERT that
# fails on its unique index (then a SELECT) on *every* resume. After the fixes,
# each distinct row is inserted at most once across the workflow's whole
# lifetime.
class ExecutionLogQueryShapeTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def test_no_redundant_execution_log_insert_attempts_across_replays
    insert_count = count_inserts_into("chrono_forge_execution_logs") do
      KitchenSink.perform_later("caching_happy_path", kwarg: "durable")
      perform_all_jobs
    end

    workflow = ChronoForge::Workflow.find_by(key: "caching_happy_path")
    assert workflow.completed?, "workflow should be completed"

    row_count = workflow.execution_logs.count
    assert_operator row_count, :>=, 5, "sanity: kitchen sink creates several step logs"

    # The crux: across all the resumes (wait_until polls, the wait reschedule,
    # etc.) each distinct execution-log row must be inserted exactly once. Any
    # excess means we are re-issuing INSERTs for steps that already exist.
    assert_equal row_count, insert_count,
      "expected one INSERT per execution-log row, got #{insert_count} INSERTs for #{row_count} rows"
  end

  def test_no_redundant_workflow_insert_attempts_across_replays
    insert_count = count_inserts_into("chrono_forge_workflows") do
      KitchenSink.perform_later("workflow_insert_path", kwarg: "durable")
      perform_all_jobs
    end

    workflow = ChronoForge::Workflow.find_by(key: "workflow_insert_path")
    assert workflow.completed?, "workflow should be completed"

    # The workflow row is created once; every subsequent resume must locate it
    # with a SELECT rather than re-attempting an INSERT that fails on the unique
    # [job_class, key] index.
    assert_equal 1, insert_count,
      "expected the workflow row to be inserted once, got #{insert_count} INSERT attempts"
  end

  private

  def count_inserts_into(table)
    count = 0
    pattern = /INSERT INTO ["`]?#{Regexp.escape(table)}/i
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      count += 1 if pattern.match?(args.last[:sql].to_s)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
