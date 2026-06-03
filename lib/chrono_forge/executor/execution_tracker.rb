module ChronoForge
  module Executor
    class ExecutionTracker
      # Total budget for the context snapshot copied into each error log.
      # Transient errors can be logged repeatedly (one row per retry), and the
      # full context always remains on the workflow itself, so the error copy
      # only needs to be a bounded diagnostic breadcrumb. Keys are preserved;
      # values are kept until the running total would exceed this budget, after
      # which each remaining value is replaced by OMITTED_VALUE. Per-value size
      # is already bounded by Context validation, so no per-value truncation is
      # needed here — a single value larger than the budget is simply replaced.
      MAX_CONTEXT_BYTESIZE = 64.kilobytes

      # Placeholder stored in place of a value that didn't fit the budget.
      OMITTED_VALUE = "<<omitted>>"

      # @param execution_log [ExecutionLog, nil] the step the error occurred in,
      #   if any. Its step_name and attempt count are recorded on the error log
      #   so errors can be attributed to a step and ordered within the workflow.
      # @param attempt [Integer, nil] explicit attempt number for errors not tied
      #   to a step (e.g. a workflow-level failure). Falls back to the execution
      #   log's attempt count.
      def self.track_error(workflow, error, execution_log: nil, attempt: nil)
        ErrorLog.create!(
          workflow: workflow,
          step_name: execution_log&.step_name,
          attempt: attempt || execution_log&.attempts,
          error_class: error.class.name,
          error_message: error.message,
          backtrace: error.backtrace&.join("\n"),
          context: error_context(workflow.context)
        )
      end

      def self.error_context(context)
        remaining = MAX_CONTEXT_BYTESIZE

        context.each_with_object({}) do |(key, value), kept|
          size = value.to_json.bytesize
          if size <= remaining
            kept[key] = value
            remaining -= size
          else
            kept[key] = OMITTED_VALUE
          end
        end
      rescue
        # If the context cannot be traversed/serialized, fail safe to a marker
        # rather than risk persisting something unbounded or unserializable.
        {"_truncated" => true}
      end
      private_class_method :error_context
    end
  end
end
