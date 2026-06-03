require "test_helper"

class ExecutionTrackerTest < ActiveJob::TestCase
  ExecutionTracker = ChronoForge::Executor::ExecutionTracker

  def setup
    ChronoForge::Workflow.destroy_all
  end

  def make_workflow(context)
    ChronoForge::Workflow.create!(
      key: "tracker_#{SecureRandom.hex(4)}",
      job_class: "KitchenSink",
      kwargs: {},
      options: {},
      context: context
    )
  end

  def boom
    raise "kaboom"
  rescue => e
    e
  end

  def test_tracks_small_context_verbatim
    workflow = make_workflow({"order_id" => "abc", "count" => 3})

    log = ExecutionTracker.track_error(workflow, boom)

    assert_equal "RuntimeError", log.error_class
    assert_equal "kaboom", log.error_message
    assert_equal workflow.context, log.context, "small context should be stored verbatim"
  end

  def test_small_context_is_kept_verbatim
    workflow = make_workflow({"a" => 1, "b" => "two"})
    log = ExecutionTracker.track_error(workflow, boom)
    assert_equal({"a" => 1, "b" => "two"}, log.context, "small contexts are stored as-is")
  end

  def test_caps_total_context_size_and_marks_overflow_values
    # Many keys that together exceed the aggregate budget. Every key is kept, but
    # values past the budget are replaced with the omitted marker.
    values = {}
    6.times { |i| values["key#{i}"] = "x" * 15_000 } # ~90 KB total > 64 KB
    workflow = make_workflow(values)

    log = ExecutionTracker.track_error(workflow, boom)

    assert_equal values.keys.sort, log.context.keys.sort, "every key is preserved"

    omitted = log.context.select { |_, v| v == ExecutionTracker::OMITTED_VALUE }.keys
    refute_empty omitted, "values past the budget should be marked omitted"

    kept_bytes = log.context.values.reject { |v| v == ExecutionTracker::OMITTED_VALUE }
      .sum { |v| v.to_json.bytesize }
    assert_operator kept_bytes, :<=, ExecutionTracker::MAX_CONTEXT_BYTESIZE,
      "the retained (non-omitted) values must stay within the aggregate budget"
  end

  def test_marks_a_value_larger_than_the_whole_budget
    workflow = make_workflow({
      "small" => "ok",
      "huge" => "x" * (ExecutionTracker::MAX_CONTEXT_BYTESIZE + 1_000)
    })

    log = ExecutionTracker.track_error(workflow, boom)

    assert_equal "ok", log.context["small"], "small sibling should be kept"
    assert_equal ExecutionTracker::OMITTED_VALUE, log.context["huge"],
      "a value larger than the budget is replaced by the marker"
    assert_equal "kaboom", log.error_message, "the error itself is always recorded"
  end
end
