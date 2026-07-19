require "test_helper"

# Automatic SolidQueue concurrency control: Executor.prepended applies a
# per-workflow-key limits_concurrency when the class supports it (spec:
# docs/superpowers/specs/2026-07-19-solid-queue-concurrency-design.md).
# solid_queue is not a dependency; FakeConcurrencyControls mimics its
# ActiveJob macro and records the arguments.
class ConcurrencyControlTest < ActiveJob::TestCase
  module FakeConcurrencyControls
    attr_reader :concurrency_args

    def limits_concurrency(**opts)
      @concurrency_args = opts
    end
  end

  def test_configuration_defaults_to_enabled
    assert_equal true, ChronoForge::Configuration.new.concurrency_control
  end

  def test_prepend_applies_per_key_limit_when_api_available
    klass = Class.new(WorkflowJob) do
      extend FakeConcurrencyControls
      prepend ChronoForge::Executor
    end

    args = klass.concurrency_args
    refute_nil args, "expected limits_concurrency to be called"
    assert_equal ChronoForge.config.max_duration + 5.seconds, args[:duration]
    # to:/on_conflict:/group: must fall through to SolidQueue defaults
    assert_equal %i[duration key], args.keys.sort
  end

  def test_key_proc_returns_workflow_key_ignoring_kwargs
    klass = Class.new(WorkflowJob) do
      extend FakeConcurrencyControls
      prepend ChronoForge::Executor
    end

    # SolidQueue instance_execs the proc with the job's arguments; the workflow
    # key is the sole positional on every enqueue path.
    assert_equal "order-123", klass.concurrency_args[:key].call("order-123", foo: 1)
  end

  def test_prepend_skips_when_disabled
    previous = ChronoForge.config.concurrency_control
    ChronoForge.config.concurrency_control = false
    klass = Class.new(WorkflowJob) do
      extend FakeConcurrencyControls
      prepend ChronoForge::Executor
    end

    assert_nil klass.concurrency_args
  ensure
    ChronoForge.config.concurrency_control = previous
  end

  def test_prepend_is_inert_without_the_api
    klass = Class.new(WorkflowJob) { prepend ChronoForge::Executor }

    refute klass.respond_to?(:limits_concurrency)
    assert klass.respond_to?(:perform_later) # prepend completed normally
  end
end
