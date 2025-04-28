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
            deep_dup(value)
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

        # Optional: Add size constraints
        if value.is_a?(String) && value.size > 64.kilobytes
          raise ValidationError, "Context value too large"
        end
      end

      def deep_dup(obj)
        JSON.parse(JSON.generate(obj))
      rescue
        obj.dup
      end
    end
  end
end
