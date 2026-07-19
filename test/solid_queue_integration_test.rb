require "test_helper"

# Integration check against the real solid_queue gem: the automatic default
# applied by Executor.prepended must compose with ActiveJob::ConcurrencyControls
# to produce a "<Class>/<workflow key>" semaphore key, with to: 1 and
# on_conflict: :block falling through as SolidQueue's own defaults. The unit
# tests in concurrency_control_test.rb stub the macro; this file is the one
# place the real gem's semantics (group/key joining, instance_exec'd key proc,
# ruby2_keywords argument flow) are exercised.
#
# solid_queue is required here, post-boot, on purpose: its engine only includes
# ConcurrencyControls into ActiveJob::Base from a Rails initializer, so a
# require after Combustion has booted defines the module without mutating
# ActiveJob::Base — the rest of the suite (including the inert-without-the-API
# test) still sees a clean ActiveJob.
require "solid_queue"

class SolidQueueIntegrationTest < ActiveJob::TestCase
  class ProbeWorkflow < WorkflowJob
    include ActiveJob::ConcurrencyControls
    prepend ChronoForge::Executor
  end

  def test_semaphore_key_is_class_slash_workflow_key
    job = ProbeWorkflow.new("order-123", foo: 1)

    assert_equal "SolidQueueIntegrationTest::ProbeWorkflow/order-123", job.concurrency_key
    assert job.concurrency_limited?
  end

  def test_solid_queue_defaults_fall_through
    assert_equal 1, ProbeWorkflow.concurrency_limit
    assert_equal :block, ProbeWorkflow.concurrency_on_conflict
    assert_equal ChronoForge.config.max_duration + 5.seconds, ProbeWorkflow.concurrency_duration
  end
end
