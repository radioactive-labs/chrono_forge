require "test_helper"

class DefinitionOverlayTest < ActiveSupport::TestCase
  include DashboardTestHelpers

  def setup
    @wf = create_workflow(key: "ov", state: :running)
    @wf.execution_logs.create!(step_name: "durably_execute$charge",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
  end

  def defn
    ChronoForge::Definition.new(
      nodes: [
        ChronoForge::Definition::Node.new(id: "n1", kind: :execute, label: "charge", step_name: "durably_execute$charge"),
        ChronoForge::Definition::Node.new(id: "n2", kind: :execute, label: "ship", step_name: "durably_execute$ship")
      ],
      edges: [], warnings: []
    )
  end

  def test_marks_done_and_not_reached
    nodes = ChronoForge::Dashboard::DefinitionOverlay.new(defn, @wf).nodes
    by_id = nodes.index_by { |n| n[:id] }
    assert_equal :done, by_id["n1"][:status]
    assert_equal :not_reached, by_id["n2"][:status]
  end

  # A merge is a JOIN: its status comes from its OWN log, not child fan-out counts
  # (children are parented to the branch log, so a merge always has 0 children).
  def test_merge_status_from_own_log
    @wf.execution_logs.create!(step_name: "merge$a,b",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    d = ChronoForge::Definition.new(
      nodes: [ChronoForge::Definition::Node.new(id: "m1", kind: :merge, label: "merge a, b", step_name: "merge$a,b")],
      edges: [], warnings: []
    )
    nodes = ChronoForge::Dashboard::DefinitionOverlay.new(d, @wf).nodes
    assert_equal :done, nodes.find { |n| n[:id] == "m1" }[:status]
  end

  # A branch still aggregates status from its child-workflow counts.
  def test_branch_status_from_child_counts
    parent = @wf.execution_logs.create!(step_name: "branch$ship",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    create_workflow(key: "child-1", state: :completed, parent_execution_log_id: parent.id)
    d = ChronoForge::Definition.new(
      nodes: [ChronoForge::Definition::Node.new(id: "b1", kind: :branch, label: "branch ship", step_name: "branch$ship")],
      edges: [], warnings: []
    )
    node = ChronoForge::Dashboard::DefinitionOverlay.new(d, @wf).nodes.find { |n| n[:id] == "b1" }
    assert_equal :done, node[:status]
    assert node.key?(:counts)
  end

  def test_appends_unmapped_logs
    @wf.execution_logs.create!(step_name: "durably_execute$mystery",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    nodes = ChronoForge::Dashboard::DefinitionOverlay.new(defn, @wf).nodes
    unmapped = nodes.select { |n| n[:status] == :unmapped }
    assert_equal ["durably_execute$mystery"], unmapped.map { |n| n[:step_name] }
  end

  # A dynamic node (computed name) binds to a log by prefix, and that log is then
  # NOT double-reported as a separate unmapped node.
  def test_dynamic_node_binds_by_prefix_without_double_report
    wf = create_workflow(key: "dyn", state: :running)
    wf.execution_logs.create!(step_name: "durably_execute$computed",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    d = ChronoForge::Definition.new(
      nodes: [ChronoForge::Definition::Node.new(
        id: "d1", kind: :dynamic, label: "durably_execute", step_name: nil,
        step_name_pattern: "durably_execute$"
      )],
      edges: [], warnings: []
    )
    nodes = ChronoForge::Dashboard::DefinitionOverlay.new(d, wf).nodes
    dyn = nodes.find { |n| n[:id] == "d1" }
    assert_equal :done, dyn[:status]
    assert_equal "durably_execute$computed", dyn[:step_name]
    assert_empty nodes.select { |n| n[:status] == :unmapped }
  end

  # A dynamic node's broad prefix ("durably_execute$") must NOT rebind a log that
  # an exact static node already owns — it binds the truly-dynamic log instead.
  def test_dynamic_node_does_not_steal_a_static_nodes_log
    # @wf already has durably_execute$charge (created first, lower id). Add the
    # computed one AFTER, so a naive .find would return charge first.
    @wf.execution_logs.create!(step_name: "durably_execute$computed",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    d = ChronoForge::Definition.new(
      nodes: [
        ChronoForge::Definition::Node.new(id: "s1", kind: :execute, label: "charge", step_name: "durably_execute$charge"),
        ChronoForge::Definition::Node.new(id: "d1", kind: :dynamic, label: "durably_execute",
          step_name: nil, step_name_pattern: "durably_execute$")
      ],
      edges: [], warnings: []
    )
    nodes = ChronoForge::Dashboard::DefinitionOverlay.new(d, @wf).nodes
    assert_equal "durably_execute$computed", nodes.find { |n| n[:id] == "d1" }[:step_name]
    assert_equal :done, nodes.find { |n| n[:id] == "s1" }[:status]
    assert_empty nodes.select { |n| n[:status] == :unmapped }
  end

  # Repetition counting uses an exact string prefix, not SQL LIKE, so underscores
  # in the step name aren't treated as single-char wildcards that over-count.
  def test_repeat_count_does_not_over_match_on_underscores
    coord = "durably_repeat$sync_ledger"
    @wf.execution_logs.create!(step_name: coord,
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1, started_at: 1.minute.ago)
    ["#{coord}$100", "#{coord}$200"].each do |s|
      @wf.execution_logs.create!(step_name: s, state: ChronoForge::ExecutionLog.states[:completed], attempts: 1)
    end
    # Differs from `coord` only where an underscore sits — a LIKE wildcard would
    # match it, an exact prefix must not.
    @wf.execution_logs.create!(step_name: "durably_repeat$syncXledger$9",
      state: ChronoForge::ExecutionLog.states[:completed], attempts: 1)
    d = ChronoForge::Definition.new(
      nodes: [ChronoForge::Definition::Node.new(id: "r1", kind: :repeat, label: "repeat", step_name: coord)],
      edges: [], warnings: []
    )
    node = ChronoForge::Dashboard::DefinitionOverlay.new(d, @wf).nodes.find { |n| n[:id] == "r1" }
    assert_equal 2, node[:repetitions]
  end

  # ExecutionLog's enum is pending/completed/failed; a pending (reached-but-
  # unfinished) log renders as :active, not the fetch default by accident.
  def test_pending_log_is_active
    @wf.execution_logs.create!(step_name: "durably_execute$ship",
      state: ChronoForge::ExecutionLog.states[:pending], attempts: 1, started_at: 1.minute.ago)
    node = ChronoForge::Dashboard::DefinitionOverlay.new(defn, @wf).nodes.find { |n| n[:id] == "n2" }
    assert_equal :active, node[:status]
  end
end
