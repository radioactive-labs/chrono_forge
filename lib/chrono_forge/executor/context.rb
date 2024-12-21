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
        # Type and size validation
        validate_value!(value)

        @context[key.to_s] =
          if value.is_a?(Hash) || value.is_a?(Array)
            deep_dup(value)
          else
            value
          end

        @dirty = true
      end

      def [](key)
        @context[key.to_s]
      end

      def save!
        return unless @dirty

        @workflow.update_column(:context, @context)
        @dirty = false
      end

      private

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
