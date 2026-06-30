module ChronoForge
  module Executor
    class Context
      class ValidationError < Error; end

      ALLOWED_TYPES = [
        String,
        Integer,
        Float,
        TrueClass,
        FalseClass,
        NilClass,
        Hash,
        Array
      ]

      # Maximum serialized byte size of a single context value. Applies to the
      # variable-length types (String, Hash, Array); scalars are unbounded in
      # practice. Measured in bytes (not characters) since that is what is
      # actually stored and what matters for write/storage cost.
      #
      # Context is meant to hold small working state (ids, flags, timestamps,
      # small structures) — not documents or payloads, which belong in their own
      # storage and can be referenced from context by id. 16 KB per value is
      # already generous for that (hundreds of ids / dozens of records).
      MAX_VALUE_BYTESIZE = 16.kilobytes

      def initialize(workflow)
        @workflow = workflow
        @context = workflow.context || {}
        @dirty = false
      end

      def []=(key, value)
        set_value(key, value)
      end

      def [](key)
        get_value(key)
      end

      # Fetches a value from the context
      # Returns the value if the key exists, otherwise returns the default value
      def fetch(key, default = nil)
        key?(key) ? get_value(key) : default
      end

      # Sets a value in the context
      # Alias for the []= method
      def set(key, value)
        set_value(key, value)
      end

      # Sets multiple values in the context at once from a hash.
      # The merge is atomic: every value is validated before any is written, so
      # a single invalid value raises and leaves the context untouched.
      # Returns self for chaining.
      def merge(hash)
        hash.each_value { |value| validate_value!(value) }
        hash.each { |key, value| set_value(key, value) }
        self
      end
      alias_method :set_multiple, :merge

      # Like #merge, but only sets keys that don't already exist; present keys
      # are skipped entirely (their values are never validated), matching
      # #set_once semantics. The applied keys are written atomically: an invalid
      # value among the new keys raises and writes nothing. Returns self.
      def merge_once(hash)
        new_pairs = hash.reject { |key, _| key?(key) }
        new_pairs.each_value { |value| validate_value!(value) }
        new_pairs.each { |key, value| set_value(key, value) }
        self
      end
      alias_method :set_multiple_once, :merge_once

      # Sets a value in the context only if the key doesn't already exist
      # Returns true if the value was set, false otherwise
      def set_once(key, value)
        return false if key?(key)

        set_value(key, value)
        true
      end

      def key?(key)
        @context.key?(key.to_s)
      end

      def save!
        return unless @dirty

        @workflow.update_column(:context, @context)
        @dirty = false
      end

      private

      def set_value(key, value)
        validate_value!(value)

        @context[key.to_s] =
          if value.is_a?(Hash) || value.is_a?(Array)
            # as_json returns a fresh JSON-compatible structure with string keys
            # — the same normalization the JSON column would apply on save and a
            # deep copy that protects the store from later mutation of the
            # source — without the cost of serializing to a string and reparsing.
            value.as_json
          else
            value
          end

        @dirty = true
      end

      def get_value(key)
        @context[key.to_s]
      end

      def validate_value!(value)
        unless ALLOWED_TYPES.any? { |type| value.is_a?(type) }
          raise ValidationError, "Unsupported context value type: #{value.inspect}"
        end

        byte_size = value_byte_size(value)
        if byte_size && byte_size > MAX_VALUE_BYTESIZE
          raise ValidationError, "Context value too large (#{byte_size} bytes, max #{MAX_VALUE_BYTESIZE})"
        end
      end

      # Serialized byte size for the variable-length types; nil for scalars,
      # which need no size constraint.
      def value_byte_size(value)
        case value
        when String then value.bytesize
        when Hash, Array then value.to_json.bytesize
        end
      end
    end
  end
end
