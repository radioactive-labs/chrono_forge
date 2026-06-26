require "test_helper"

class SpawnEachTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    User.delete_all
    @users = 5.times.map { |i| User.create!(name: "u#{i}", email: "u#{i}@e.com") }
  end

  def test_spawn_each_creates_one_indexed_child_per_item
    SpawnEachWorkflow.perform_later("se-1")
    perform_all_jobs

    parent = ChronoForge::Workflow.find_by(key: "se-1")
    branch_log = parent.execution_logs.find_by(step_name: "branch$grp")
    children = ChronoForge::Workflow.where(parent_execution_log_id: branch_log.id).order(:key)

    assert_equal @users.map { |u| "se-1$grp$items_#{u.id}" }.sort, children.pluck(:key).sort
    assert_equal 5, children.count
    cursor = branch_log.reload.metadata["cursors"]["items"]
    assert_equal @users.last.id, cursor["pk"]
  end

  def test_spawn_each_honors_class_from_block
    klass = Class.new(WorkflowJob) { prepend ChronoForge::Executor; def perform(**) = nil }
    Object.const_set(:AltChild, klass)
    job = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      def perform
        branch(:g, automerge: true) do
          spawn_each(:i, User.all) { |u| u.id.even? ? [AltChild, {id: u.id}] : [NoopChild, {id: u.id}] }
        end
      end
    end
    Object.const_set(:MixedClassWorkflow, job)

    MixedClassWorkflow.perform_later("mc-1")
    perform_all_jobs

    classes = ChronoForge::Workflow.where("key LIKE ?", "mc-1$g$i_%").pluck(:job_class).uniq.sort
    assert_equal %w[AltChild NoopChild], classes
  ensure
    Object.send(:remove_const, :AltChild) if defined?(AltChild)
    Object.send(:remove_const, :MixedClassWorkflow) if defined?(MixedClassWorkflow)
  end

  def test_spawn_each_raises_on_conflicting_order
    job = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      def perform
        branch(:g, automerge: true) do
          spawn_each(:i, User.order(:email)) { |u| [NoopChild, {id: u.id}] }
        end
      end
    end
    Object.const_set(:BadOrderWorkflow, job)
    BadOrderWorkflow.perform_later("bo-1")
    assert_raises(ChronoForge::Executor::NotExecutableError) { perform_all_jobs }
  ensure
    Object.send(:remove_const, :BadOrderWorkflow) if defined?(BadOrderWorkflow)
  end

  def test_spawn_each_over_plain_enumerable
    job = Class.new(WorkflowJob) do
      prepend ChronoForge::Executor
      def perform
        branch(:g, automerge: true) do
          spawn_each(:n, [10, 20, 30]) { |val| [NoopChild, {val: val}] }
        end
      end
    end
    Object.const_set(:EnumWorkflow, job)
    EnumWorkflow.perform_later("en-1")
    perform_all_jobs

    keys = ChronoForge::Workflow.where("key LIKE ?", "en-1$g$n_%").order(:key).pluck(:key)
    assert_equal %w[en-1$g$n_0 en-1$g$n_1 en-1$g$n_2], keys
  ensure
    Object.send(:remove_const, :EnumWorkflow) if defined?(EnumWorkflow)
  end
end
