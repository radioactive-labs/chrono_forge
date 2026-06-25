require "test_helper"

class PresentersTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  def log(wf, step_name, state:, attempts: 1, started_at: Time.current, completed_at: nil, **attrs)
    ChronoForge::ExecutionLog.create!(workflow: wf, step_name: step_name,
      state: ChronoForge::ExecutionLog.states[state], attempts: attempts,
      started_at: started_at, completed_at: completed_at, **attrs)
  end

  test "timeline orders and rolls up repetitions" do
    wf = create_workflow(key: "t1")
    log(wf, "durably_execute$validate", state: :completed, started_at: 3.minutes.ago)
    log(wf, "durably_repeat$remind", state: :pending, started_at: 2.minutes.ago)
    log(wf, "durably_repeat$remind$1717000000", state: :completed, started_at: 1.minute.ago)

    tl = ChronoForge::Dashboard::TimelinePresenter.new(wf)
    kinds = tl.entries.map(&:kind)
    assert_equal :execute, kinds.first
    repeat = tl.entries.find { |e| e.kind == :repeat_coordination }
    assert_equal 1, repeat.runs.size
  end

  test "current position is the failed step" do
    wf = create_workflow(key: "t2", state: :failed)
    log(wf, "durably_execute$a", state: :completed, started_at: 2.minutes.ago)
    failed = log(wf, "durably_execute$b", state: :failed, started_at: 1.minute.ago, error_class: "Boom")
    tl = ChronoForge::Dashboard::TimelinePresenter.new(wf)
    assert_equal failed.id, tl.current_position.id
  end

  test "context presenter exposes typed nodes and size" do
    wf = create_workflow(key: "t3", context: { "amount" => 5, "intl" => true })
    cp = ChronoForge::Dashboard::ContextPresenter.new(wf)
    types = cp.nodes.map { |n| [n[:key], n[:type]] }.to_h
    assert_equal "Integer", types["amount"]
    assert_equal "TrueClass", types["intl"]
    assert_operator cp.byte_size, :>, 0
  end
end
