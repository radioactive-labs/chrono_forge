require "test_helper"

class ContinuationFlushTest < ActiveJob::TestCase
  include ChaoticJob::Helpers

  def setup
    ChronoForge::Workflow.destroy_all
  end

  # The core ordering guarantee: a continuation must only become claimable after
  # the enqueuing job has released the lock. We observe the workflow's lock owner
  # in the DB at the instant each same-key continuation is enqueued; it must be nil.
  def test_continuation_is_enqueued_only_after_lock_released
    key = "flush_order_#{Time.now.to_i}_#{rand(10_000)}"

    locked_owners = []
    # Continuations are scheduled via `.set(wait:).perform_later`, which fires
    # `enqueue_at.active_job` (not `enqueue.active_job`). Subscribe to both so we
    # observe the lock owner at the instant the continuation is published.
    handler = lambda do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      job = event.payload[:job]
      next unless job.arguments.first == key
      wf = ChronoForge::Workflow.find_by(key: key)
      locked_owners << (wf && wf.locked_by)
    end
    subscribers = [
      ActiveSupport::Notifications.subscribe("enqueue.active_job", &handler),
      ActiveSupport::Notifications.subscribe("enqueue_at.active_job", &handler)
    ]

    begin
      WaitContinuationJob.perform_later(key)
      perform_all_jobs_before(1.second)
    ensure
      subscribers.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
    end

    refute locked_owners.empty?, "expected to observe a continuation enqueue"
    assert locked_owners.all?(&:nil?),
      "continuation must be enqueued only after lock release; observed owners: #{locked_owners.inspect}"
  end

  # flush_continuation! must round-trip arbitrary kwargs into the continuation.
  def test_flush_continuation_preserves_kwargs
    key = "flush_kwargs_#{Time.now.to_i}_#{rand(10_000)}"
    workflow = ChronoForge::Workflow.create!(
      key: key, job_class: "KitchenSink", kwargs: {}, options: {}, context: {}, state: :idle
    )

    job = KitchenSink.new
    job.instance_variable_set(:@workflow, workflow)
    job.send(:enqueue_continuation, wait: 0.seconds, wait_condition: "my_cond")

    assert_difference -> { enqueued_jobs.size }, 1 do
      job.send(:flush_continuation!)
    end

    last = enqueued_jobs.last
    assert_includes last.to_s, key, "continuation should target the workflow key"
    assert_includes last.to_s, "my_cond", "continuation must carry the wait_condition kwarg"
  end

  def test_flush_continuation_is_noop_without_recorded_continuation
    job = KitchenSink.new
    assert_no_difference -> { enqueued_jobs.size } do
      job.send(:flush_continuation!)
    end
  end

  # If context.save! fails in the ensure block, the lock must STILL be released and
  # the recorded continuation STILL published — otherwise a transient save failure
  # would strand the workflow (lock held until stale, nothing scheduled to resume).
  def test_lock_release_and_continuation_survive_context_save_failure
    key = "save_fail_#{rand(100_000)}"

    ChronoForge::Executor::Context.class_eval { alias_method :__orig_save!, :save! }
    ChronoForge::Executor::Context.define_method(:save!) { raise "boom" }
    begin
      assert_raises(RuntimeError) { WaitContinuationJob.perform_now(key) }
    ensure
      ChronoForge::Executor::Context.class_eval do
        alias_method :save!, :__orig_save!
        remove_method :__orig_save!
      end
    end

    wf = ChronoForge::Workflow.find_by(key: key)
    assert wf, "workflow row should exist"
    assert_nil wf.locked_by, "lock must be released even when context.save! raises"
    assert_equal "idle", wf.state, "workflow must be returned to idle, not left running"
    assert(enqueued_jobs.any? { |j| j.to_s.include?(key) },
      "the continuation must still be published when context.save! raises")
  end
end

class WaitContinuationJob < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    wait 1.hour, "long_wait"
  end
end
