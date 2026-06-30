require "test_helper"

class ContextTest < ActiveJob::TestCase
  Context = ChronoForge::Executor::Context

  def build_context(initial = {})
    workflow = ChronoForge::Workflow.new(
      key: "ctx_#{SecureRandom.hex(4)}",
      job_class: "KitchenSink",
      kwargs: {},
      options: {},
      context: initial
    )
    Context.new(workflow)
  end

  def test_stores_a_deep_copy_so_caller_mutation_does_not_leak
    context = build_context
    original = {"items" => [1, 2, 3]}

    context[:payload] = original
    original["items"] << 4
    original["added"] = true

    assert_equal({"items" => [1, 2, 3]}, context[:payload],
      "stored value must be a deep copy, immune to later mutation of the source")
  end

  def test_normalizes_symbol_keys_to_strings
    context = build_context

    context[:data] = {a: 1, nested: {b: 2}}

    assert_equal({"a" => 1, "nested" => {"b" => 2}}, context[:data],
      "hash keys should be normalized to strings (JSON-compatible)")
  end

  def test_rejects_oversized_string
    context = build_context
    assert_raises(Context::ValidationError) do
      context[:big] = "x" * (Context::MAX_VALUE_BYTESIZE + 1)
    end
  end

  def test_rejects_oversized_hash
    context = build_context
    big = {"blob" => "x" * (Context::MAX_VALUE_BYTESIZE + 1_000)}
    assert_raises(Context::ValidationError) do
      context[:big] = big
    end
  end

  def test_rejects_oversized_array
    context = build_context
    assert_raises(Context::ValidationError) do
      context[:big] = ["x" * (Context::MAX_VALUE_BYTESIZE + 1_000)]
    end
  end

  def test_allows_values_under_the_limit
    context = build_context
    context[:ok_string] = "x" * 1_000
    context[:ok_hash] = {"a" => [1, 2, 3]}

    assert_equal "x" * 1_000, context[:ok_string]
    assert_equal({"a" => [1, 2, 3]}, context[:ok_hash])
  end

  def test_merge_sets_multiple_keys_at_once
    context = build_context

    context.merge(status: "active", total: 99.99, count: 3)

    assert_equal "active", context[:status]
    assert_equal 99.99, context[:total]
    assert_equal 3, context[:count]
  end

  def test_merge_normalizes_symbol_keys_and_stores_deep_copies
    context = build_context
    source = {"items" => [1, 2, 3]}

    context.merge(payload: source, flag: true)
    source["items"] << 4

    assert_equal({"items" => [1, 2, 3]}, context[:payload],
      "merged values must be deep copies, immune to later mutation of the source")
    assert_equal true, context[:flag]
  end

  def test_merge_is_atomic_when_a_value_is_invalid
    context = build_context
    context[:existing] = "keep"

    assert_raises(Context::ValidationError) do
      context.merge(ok: "fine", big: "x" * (Context::MAX_VALUE_BYTESIZE + 1))
    end

    assert_equal "keep", context[:existing]
    refute context.key?(:ok),
      "no key should be written when any value in the merge is invalid"
  end

  def test_set_multiple_is_an_alias_for_merge
    context = build_context

    context.set_multiple(a: 1, b: 2)

    assert_equal 1, context[:a]
    assert_equal 2, context[:b]
  end

  def test_merge_returns_self_for_chaining
    context = build_context

    assert_same context, context.merge(a: 1)
  end

  def test_merge_with_empty_hash_is_a_no_op
    context = build_context

    assert_same context, context.merge({})
    refute context.key?(:anything)
  end

  def test_merge_once_sets_only_absent_keys
    context = build_context
    context[:status] = "existing"

    context.merge_once(status: "new", count: 5)

    assert_equal "existing", context[:status], "present keys must not be overwritten"
    assert_equal 5, context[:count], "absent keys should be set"
  end

  def test_merge_once_skips_present_keys_without_validating_them
    context = build_context
    context[:status] = "existing"

    # The oversized value sits under an already-present key, so it is skipped
    # entirely — never validated — matching set_once semantics.
    context.merge_once(status: "x" * (Context::MAX_VALUE_BYTESIZE + 1), count: 5)

    assert_equal "existing", context[:status]
    assert_equal 5, context[:count]
  end

  def test_merge_once_is_atomic_across_the_new_keys
    context = build_context

    assert_raises(Context::ValidationError) do
      context.merge_once(ok: "fine", big: "x" * (Context::MAX_VALUE_BYTESIZE + 1))
    end

    refute context.key?(:ok), "no new key should be written when any new value is invalid"
  end

  def test_set_multiple_once_is_an_alias_for_merge_once
    context = build_context

    context.set_multiple_once(a: 1, b: 2)

    assert_equal 1, context[:a]
    assert_equal 2, context[:b]
  end

  def test_merge_once_returns_self_for_chaining
    context = build_context

    assert_same context, context.merge_once(a: 1)
  end

  def test_preserves_scalar_values
    context = build_context

    context[:n] = 42
    context[:f] = 1.5
    context[:s] = "hi"
    context[:flag] = true
    context[:nothing] = nil

    assert_equal 42, context[:n]
    assert_equal 1.5, context[:f]
    assert_equal "hi", context[:s]
    assert_equal true, context[:flag]
    assert_nil context[:nothing]
  end
end
