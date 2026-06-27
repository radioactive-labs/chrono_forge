require "test_helper"

class PresentersTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  def log(wf, step_name, state:, attempts: 1, started_at: Time.current, completed_at: nil, **attrs)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: step_name,
      state: ChronoForge::ExecutionLog.states[state], attempts: attempts,
      started_at: started_at, completed_at: completed_at, **attrs)
  end

  test "timeline orders steps and summarizes repetitions without inlining runs" do
    wf = create_workflow(key: "t1")
    log(wf, "durably_execute$validate", state: :completed, started_at: 3.minutes.ago)
    log(wf, "durably_repeat$remind", state: :pending, started_at: 2.minutes.ago)
    log(wf, "durably_repeat$remind$1717000000", state: :completed, started_at: 90.seconds.ago)
    log(wf, "durably_repeat$remind$1717000600", state: :failed, started_at: 1.minute.ago)

    tl = ChronoForge::Dashboard::TimelinePresenter.new(wf)
    # Run logs are excluded from the timeline entries entirely.
    assert_equal 2, tl.entries.size
    assert_equal :execute, tl.entries.first.kind

    repeat = tl.entries.find { |e| e.kind == :repeat_coordination }
    assert_equal 2, repeat.iterations
    assert_equal 1, repeat.tombstones
  end

  test "timeline attaches error logs to their step for inline rendering" do
    wf = create_workflow(key: "te", state: :stalled)
    log(wf, "durably_execute$charge", state: :failed, started_at: 1.minute.ago, error_class: "Boom")
    ChronoForge::ErrorLog.create!(workflow: wf, step_name: "durably_execute$charge", attempt: 2,
      error_class: "Boom", error_message: "kaboom", backtrace: "a.rb:1")

    step = ChronoForge::Dashboard::TimelinePresenter.new(wf).entries.find { |e| e.name == "charge" }
    assert_equal 1, step.errors.size
    assert_equal "kaboom", step.errors.first.error_message
  end

  test "workflow-level failure error attaches to the failure marker by id" do
    wf = create_workflow(key: "wl-fail", state: :failed)
    log(wf, "durably_execute$charge", state: :pending, started_at: 2.minutes.ago)
    err = ChronoForge::ErrorLog.create!(workflow: wf, step_name: nil, attempt: 1,
      error_class: "BoomError", error_message: "kaboom")
    log(wf, "$workflow_failure$#{err.id}", state: :completed, started_at: 1.minute.ago, completed_at: 1.minute.ago)

    tl = ChronoForge::Dashboard::TimelinePresenter.new(wf)
    marker = tl.entries.find { |e| e.kind == :lifecycle }
    assert_equal [err.id], marker.errors.map(&:id)
    assert_empty tl.orphan_errors, "the error is shown on the marker, so not an orphan"
  end

  test "a failure marker whose error log is gone notes the missing id" do
    wf = create_workflow(key: "gone-err", state: :failed)
    log(wf, "$workflow_failure$999999", state: :completed, started_at: 1.minute.ago, completed_at: 1.minute.ago)

    marker = ChronoForge::Dashboard::TimelinePresenter.new(wf).entries.find { |e| e.kind == :lifecycle }
    assert_empty marker.errors
    assert_equal 999999, marker.missing_error_id
  end

  test "an error log attached to no step is surfaced as an orphan" do
    wf = create_workflow(key: "orphan-err", state: :failed)
    log(wf, "durably_execute$charge", state: :pending, started_at: 1.minute.ago)
    err = ChronoForge::ErrorLog.create!(workflow: wf, step_name: nil, attempt: 1,
      error_class: "BoomError", error_message: "kaboom")

    assert_equal [err.id], ChronoForge::Dashboard::TimelinePresenter.new(wf).orphan_errors.map(&:id)
  end

  test "current position is the failed step" do
    wf = create_workflow(key: "t2", state: :failed)
    log(wf, "durably_execute$a", state: :completed, started_at: 2.minutes.ago)
    failed = log(wf, "durably_execute$b", state: :failed, started_at: 1.minute.ago, error_class: "Boom")
    tl = ChronoForge::Dashboard::TimelinePresenter.new(wf)
    assert_equal failed.id, tl.current_position.id
  end

  test "context presenter exposes typed nodes and size" do
    wf = create_workflow(key: "t3", context: {"amount" => 5, "intl" => true})
    cp = ChronoForge::Dashboard::ContextPresenter.new(wf)
    types = cp.nodes.map { |n| [n[:key], n[:type]] }.to_h
    assert_equal "Integer", types["amount"]
    assert_equal "TrueClass", types["intl"]
    assert_operator cp.byte_size, :>, 0
  end
end
