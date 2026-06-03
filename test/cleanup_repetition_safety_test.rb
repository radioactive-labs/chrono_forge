require "test_helper"

# A durably_repeat workflow that records the scheduled time of every execution,
# so we can prove pruning never causes an occurrence to run twice.
class PrunableRepeatJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    context.set_once("ticks", [])
    durably_repeat :tick, every: 1.second, till: :done?
  end

  private

  def tick(scheduled_time = nil)
    ticks = context.fetch("ticks", [])
    ticks << scheduled_time&.to_i
    context["ticks"] = ticks
  end

  def done?
    context.fetch("ticks", []).size >= 6
  end
end

# The critical guarantee: pruning behind-frontier repetition logs must not affect
# how the periodic task continues — no occurrence re-executes, and the task still
# reaches its `till` condition.
class CleanupRepetitionSafetyTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def test_pruning_does_not_re_execute_occurrences_or_break_continuation
    key = "prune_safety_#{Time.now.to_i}_#{rand(1000)}"
    PrunableRepeatJob.perform_later(key)

    # Run a few iterations so there are completed repetition logs behind the
    # current frontier (eligible for pruning).
    perform_all_jobs_before(4.seconds)

    workflow = ChronoForge::Workflow.find_by(key: key)
    ticks_before = workflow.reload.context["ticks"].dup
    assert_operator ticks_before.size, :>=, 2, "precondition: a few occurrences have executed"

    reps_before = workflow.execution_logs.where("step_name LIKE ?", "durably_repeat$tick$%").count

    # Prune everything safely prunable (terminal logs strictly behind the
    # frontier). The window of 0 makes every past occurrence window-eligible, so
    # only the frontier guard governs what is kept.
    result = ChronoForge::Cleanup.run(older_than: 365.days, prune_repetition_logs_older_than: 0.seconds)

    assert_operator result[:repetition_logs], :>=, 1,
      "precondition: pruning must actually remove behind-frontier repetition logs for this test to mean anything"

    reps_after_prune = workflow.execution_logs.where("step_name LIKE ?", "durably_repeat$tick$%").count
    assert_operator reps_after_prune, :<, reps_before, "pruning should have removed some repetition logs"
    assert workflow.execution_logs.exists?(step_name: "durably_repeat$tick"),
      "coordination log must survive pruning"

    # Continue the workflow to completion.
    perform_all_jobs_before(20.seconds)
    workflow.reload

    ticks_after = workflow.context["ticks"]

    assert workflow.completed?, "workflow must still complete after pruning"
    assert_equal ticks_after.uniq, ticks_after,
      "no occurrence may execute twice after its log was pruned"
    assert_equal 6, ticks_after.size,
      "must execute exactly the required number of times — no occurrences lost or repeated"
    assert_equal ticks_before, ticks_after.first(ticks_before.size),
      "already-executed occurrences must remain a stable prefix (pruned ones are never re-run)"
  end
end
