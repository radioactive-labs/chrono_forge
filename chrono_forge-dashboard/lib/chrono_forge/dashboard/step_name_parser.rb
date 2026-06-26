module ChronoForge
  module Dashboard
    module StepNameParser
      Parsed = Struct.new(:kind, :name, :timestamp, :raw)
      DELIM = "$"

      def self.parse(step_name)
        prefix, name, ts = step_name.to_s.split(DELIM, 3)
        case prefix
        when "" # framework lifecycle markers: $workflow_completion$, $workflow_failure$<id>, $workflow_retry$<ts>
          # The trailing segment is the error-log id for failures (a timestamp for retries).
          Parsed.new(kind: :lifecycle, name: name.to_s.delete_prefix("workflow_"),
            timestamp: Integer(ts, exception: false), raw: step_name)
        when "durably_execute" then Parsed.new(kind: :execute, name: name, raw: step_name)
        when "wait" then Parsed.new(kind: :sleep, name: name, raw: step_name)
        when "wait_until" then Parsed.new(kind: :wait, name: name, raw: step_name)
        when "continue_if" then Parsed.new(kind: :continue, name: name, raw: step_name)
        when "durably_repeat"
          if ts
            Parsed.new(kind: :repeat_run, name: name, timestamp: Integer(ts, exception: false), raw: step_name)
          else
            Parsed.new(kind: :repeat_coordination, name: name, raw: step_name)
          end
        else
          Parsed.new(kind: :unknown, name: step_name, raw: step_name)
        end
      end
    end
  end
end
