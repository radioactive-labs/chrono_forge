require "test_helper"

class NoopCompletionWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    # No durable steps: the only execution log is the completion marker.
  end
end

class SingleStepWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  # base/cap 0 so retries run inline within one perform_all_jobs.
  retry_policy max_attempts: 3, base: 0, cap: 0, jitter: false

  cattr_accessor :fail_times, default: 0
  cattr_accessor :calls, default: 0

  def perform
    durably_execute :do_work
  end

  def do_work
    self.class.calls += 1
    raise "boom" if self.class.calls <= self.class.fail_times
  end
end

class AlwaysFailsWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  # No workflow-level retries: a raw error in perform goes straight to the
  # workflow-failure marker (a failing durably_execute step would stall, not fail).
  retry_policy max_attempts: 1, base: 0, cap: 0, jitter: false

  def perform
    raise "always boom"
  end
end

class GatedWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  cattr_accessor :open, default: false

  def perform
    continue_if :ready?
  end

  def ready?
    self.class.open
  end
end

class RepeatOnceWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    durably_repeat :tick, every: 2.seconds, till: :done?
  end

  def tick
    context[:n] = context.fetch(:n, 0) + 1
  end

  def done?
    context.fetch(:n, 0) >= 1
  end
end

class WriteConsolidationTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def test_failure_marker_is_born_completed_in_a_single_insert
    inserts, updates = count_named_log_writes(/\$workflow_failure\$/) do
      AlwaysFailsWorkflow.perform_later("fail_#{Time.now.to_i}")
      perform_all_jobs
    end

    workflow = ChronoForge::Workflow.last
    assert workflow.failed?, "workflow should have failed"

    failure = workflow.execution_logs.where("step_name LIKE ?", "$workflow_failure$%").last
    assert failure.completed?, "failure marker should be recorded as completed"

    # The failure marker is written in its terminal state: one INSERT, no
    # started→completed UPDATE chasing it.
    assert_equal 1, inserts, "expected one failure-marker INSERT, got #{inserts}"
    assert_equal 0, updates, "failure marker should need no follow-up UPDATE, got #{updates}"
  end

  def test_durably_repeat_first_repetition_records_attempt_in_the_insert
    bumps = count_attempt_only_updates do
      RepeatOnceWorkflow.perform_later("rep_#{Time.now.to_i}")
      perform_all_jobs_before(1.second)
    end

    workflow = ChronoForge::Workflow.last
    rep = workflow.execution_logs.find { |l| l.step_name.include?("durably_repeat$tick$") }
    assert rep, "first repetition log should have been created"
    assert_equal 1, rep.attempts, "first repetition attempt should be recorded in the INSERT"

    # Creating a (scheduled-for-later) repetition should not issue a separate
    # attempt-bump UPDATE.
    assert_equal 0, bumps,
      "creating a repetition should not issue a separate attempt-bump UPDATE, got #{bumps}"
  end

  def test_continue_if_first_run_records_attempt_in_the_insert
    GatedWorkflow.open = true
    bumps = count_attempt_only_updates do
      GatedWorkflow.perform_later("gate_#{Time.now.to_i}")
      perform_all_jobs
    end

    workflow = ChronoForge::Workflow.last
    assert workflow.completed?, "workflow should complete when the gate is open"
    gate = workflow.execution_logs.find_by(step_name: "continue_if$ready?")
    assert gate.completed?, "gate should be completed"
    assert_equal 1, gate.attempts, "first evaluation should be recorded"

    assert_equal 0, bumps,
      "first continue_if evaluation should not issue a separate attempt-bump UPDATE, got #{bumps}"
  ensure
    GatedWorkflow.open = false
  end

  def test_completion_marker_is_born_completed_in_a_single_insert
    inserts, updates = count_execution_log_writes do
      NoopCompletionWorkflow.perform_later("noop_#{Time.now.to_i}")
      perform_all_jobs
    end

    workflow = ChronoForge::Workflow.last
    assert workflow.completed?, "workflow should complete"

    completion = workflow.execution_logs.find_by(step_name: "$workflow_completion$")
    assert completion.completed?, "completion log should be marked completed"
    assert_equal 1, completion.attempts, "completion attempt should be recorded"
    assert completion.completed_at, "completion timestamp should be set"

    # The marker is created already in its terminal state: one INSERT, no
    # started→completed UPDATE chasing it.
    assert_equal 1, inserts, "expected exactly one completion-marker INSERT, got #{inserts}"
    assert_equal 0, updates, "completion marker should need no follow-up UPDATE, got #{updates}"
  end

  def test_completion_writes_share_a_single_transaction
    stream = capture_sql do
      NoopCompletionWorkflow.perform_later("noop_#{Time.now.to_i}")
      perform_all_jobs
    end

    # complete_workflow! does two writes with no external side effect between
    # them: INSERT the (already-completed) marker and UPDATE the workflow to
    # :completed. They must commit together so a trivial child pays one fsync here.
    insert_i = stream.index { |s| s.match?(/INSERT INTO ["`]?chrono_forge_execution_logs/i) }
    # The completion UPDATE sets completed_at; release_lock's later UPDATE sets
    # locked_at/locked_by — target the former specifically.
    wf_update_i = stream.index { |s| s.match?(/UPDATE ["`]?chrono_forge_workflows.*completed_at/i) }
    refute_nil insert_i, "expected a completion-marker INSERT"
    refute_nil wf_update_i, "expected a workflow completion UPDATE"

    lo, hi = [insert_i, wf_update_i].minmax
    enclosed = stream[lo..hi]
    commits = enclosed.count { |s| s.strip.match?(/\Acommit\b/i) }
    assert_equal 0, commits,
      "completion marker INSERT and workflow UPDATE must share one " \
      "transaction (found #{commits} commit(s) between them)"
  end

  def test_first_step_run_records_attempt_in_the_insert
    SingleStepWorkflow.fail_times = 0
    SingleStepWorkflow.calls = 0
    bumps = count_attempt_only_updates do
      SingleStepWorkflow.perform_later("step_ok_#{Time.now.to_i}")
      perform_all_jobs
    end

    workflow = ChronoForge::Workflow.last
    assert workflow.completed?, "workflow should complete"
    step = workflow.execution_logs.find_by(step_name: "durably_execute$do_work")
    assert step.completed?, "step should be completed"
    assert_equal 1, step.attempts, "first attempt should be recorded"

    # On a fresh step the attempt is baked into the INSERT — no separate
    # pre-execution attempt-bump UPDATE.
    assert_equal 0, bumps,
      "first run should not issue a separate attempt-bump UPDATE, got #{bumps}"
  end

  def test_retry_run_bumps_attempt_with_an_update
    # Fail once, then succeed: the step log already exists on the second attempt,
    # so the pre-execution attempt bump must still be issued as an UPDATE.
    SingleStepWorkflow.fail_times = 1
    SingleStepWorkflow.calls = 0
    bumps = count_attempt_only_updates do
      SingleStepWorkflow.perform_later("step_retry_#{Time.now.to_i}")
      perform_all_jobs
    end

    workflow = ChronoForge::Workflow.last
    assert workflow.completed?, "workflow should complete after retry"
    step = workflow.execution_logs.find_by(step_name: "durably_execute$do_work")
    assert_equal 2, step.attempts, "retry should record a second attempt"

    assert_operator bumps, :>=, 1,
      "a retry (existing log) should bump the attempt with an UPDATE"
  ensure
    SingleStepWorkflow.fail_times = 0
    SingleStepWorkflow.calls = 0
  end

  private

  def count_attempt_only_updates
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      sql = args.last[:sql].to_s
      next unless /UPDATE ["`]?chrono_forge_execution_logs/i.match?(sql)
      # The pre-execution bump sets attempts/last_executed_at but not state; the
      # completion write sets state. Count only the former.
      count += 1 if /\battempts\b/i.match?(sql) && !/\bstate\b/i.match?(sql)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def count_execution_log_writes
    inserts = 0
    updates = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      sql = args.last[:sql].to_s
      inserts += 1 if /INSERT INTO ["`]?chrono_forge_execution_logs/i.match?(sql)
      updates += 1 if /UPDATE ["`]?chrono_forge_execution_logs/i.match?(sql)
    end
    yield
    [inserts, updates]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # INSERT/UPDATE counts to execution_logs, but only for statements whose bound
  # values include a step_name matching `pattern` (so other steps' writes — the
  # failing durably_execute step, the completion marker — don't pollute the count).
  def count_named_log_writes(pattern)
    inserts = 0
    updates = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = args.last
      sql = payload[:sql].to_s
      next unless /(INSERT INTO|UPDATE) ["`]?chrono_forge_execution_logs/i.match?(sql)
      values = (payload[:type_casted_binds] || payload[:binds] || []).map { |b| b.respond_to?(:value) ? b.value : b }
      next unless values.any? { |v| v.is_a?(String) && pattern.match?(v) }
      # Classify by statement type, not a bare /UPDATE/ — the latter matches the
      # `updated_at` column name in an INSERT's column list.
      inserts += 1 if /\AINSERT INTO/i.match?(sql.lstrip)
      updates += 1 if /\AUPDATE/i.match?(sql.lstrip)
    end
    yield
    [inserts, updates]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def capture_sql
    stream = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      sql = args.last[:sql].to_s
      next if sql.start_with?("PRAGMA", "SAVEPOINT", "RELEASE")
      stream << sql
    end
    yield
    stream
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
