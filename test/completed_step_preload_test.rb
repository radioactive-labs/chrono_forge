require "test_helper"

# A workflow with a configurable number of durable steps in front of a gate
# that never opens. The first pass completes every step then halts at the gate;
# any subsequent resume replays all the completed steps before halting again.
class PreloadGatedWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform(steps:)
    steps.times { |i| durably_execute :noop_step, name: "step_#{i}" }
    continue_if :gate_open?
  end

  private

  def noop_step
    # no-op; the point is the execution-log bookkeeping, not the work
  end

  def gate_open?
    context[:gate] == true
  end
end

# Regression test for the replay-loop read shape.
#
# The engine replays the whole workflow body on every resume. Completed steps
# are short-circuited, but each one used to cost its own indexed SELECT, so a
# workflow with hundreds of completed steps paid hundreds of SELECTs per resume
# (quadratic over its lifetime). Completed steps must instead be resolved from a
# single bulk read, so the per-resume read count is constant regardless of how
# many steps have already completed.
class CompletedStepPreloadTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def test_resume_read_count_is_constant_regardless_of_completed_step_count
    few = resume_execution_log_selects("preload_few", steps: 3)
    many = resume_execution_log_selects("preload_many", steps: 25)

    assert_equal few, many,
      "execution-log SELECTs on resume scaled with completed-step count " \
      "(#{few} for 3 steps vs #{many} for 25) — completed steps are not being preloaded"
  end

  def test_completed_step_cache_excludes_durably_repeat_repetition_logs
    workflow = ChronoForge::Workflow.create!(
      job_class: "PreloadGatedWorkflow", key: "repeat_exclusion",
      context: {}, kwargs: {}, options: {}
    )

    linear = ChronoForge::ExecutionLog.create!(
      workflow: workflow, step_name: "durably_execute$send_email", state: :completed
    )
    coordination = ChronoForge::ExecutionLog.create!(
      workflow: workflow, step_name: "durably_repeat$poll", state: :completed
    )
    repetition = ChronoForge::ExecutionLog.create!(
      workflow: workflow, step_name: "durably_repeat$poll$1700000000", state: :completed
    )

    job = PreloadGatedWorkflow.new
    job.instance_variable_set(:@workflow, workflow)
    cache = job.send(:completed_step_cache)

    assert cache.key?(linear.step_name), "linear steps must be cached"
    assert cache.key?(coordination.step_name),
      "the durably_repeat coordination log must be cached"
    refute cache.key?(repetition.step_name),
      "unbounded durably_repeat repetition logs must be excluded from the cache"
  end

  private

  # Runs the workflow once (first pass halts at the closed gate), then counts the
  # execution-log SELECTs issued during a single resume.
  def resume_execution_log_selects(key, steps:)
    PreloadGatedWorkflow.perform_later(key, steps: steps)
    perform_all_jobs

    workflow = ChronoForge::Workflow.find_by(key: key)
    assert_equal steps, workflow.execution_logs.completed.count,
      "sanity: all #{steps} steps should be completed before resume"

    count_execution_log_selects do
      PreloadGatedWorkflow.perform_later(key)
      perform_all_jobs
    end
  end

  def count_execution_log_selects
    count = 0
    pattern = /SELECT .* FROM ["`]?chrono_forge_execution_logs/i
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      count += 1 if pattern.match?(args.last[:sql].to_s)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
