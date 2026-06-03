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
