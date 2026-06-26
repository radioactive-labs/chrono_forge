module ChronoForge
  module Dashboard
    # Time-bucketed completion/failure/duration metrics over a window.
    #
    # The aggregation runs in the database (GROUP BY a per-day bucket), so it
    # returns one row per day regardless of how many workflows match — it never
    # loads workflow rows into Ruby. The bucket and duration expressions are
    # adapter-specific (SQLite / PostgreSQL / MySQL), chosen once per query.
    #
    # Scale note: completed workflows are bucketed (and windowed) by
    # `completed_at`, which is the leading-range column of the existing
    # `[state, completed_at]` index, so the heavy path (millions of completed
    # rows) is an index range scan. Failed workflows have no `completed_at`, so
    # they are bucketed by `updated_at` (when they reached the failed state) —
    # a tiny set in practice. The two terminal axes are merged per day.
    #
    # Rates here are WORKFLOW-level, not execution-log level: a high count of
    # failed *execution logs* is normal durably_repeat catch-up churn, whereas a
    # failed *workflow* is a real incident. This query only ever counts
    # workflows.
    class AnalyticsQuery
      WINDOWS = {"24h" => 1.day, "7d" => 7.days, "30d" => 30.days}.freeze
      DEFAULT_WINDOW = "7d"

      Bucket = Struct.new(:day, :completed, :failed, :avg_duration) do
        def terminal = completed + failed
      end

      def initialize(window: DEFAULT_WINDOW, job_class: nil, now: Time.current)
        @window = WINDOWS.key?(window.presence) ? window : DEFAULT_WINDOW
        @job_class = job_class.presence
        @now = now
        @since = now - WINDOWS.fetch(@window)
      end

      attr_reader :window, :since, :job_class

      def windows = WINDOWS.keys

      # Per-day buckets within the window, oldest first.
      def buckets = data[:buckets]

      # Roll-ups over the whole window: counts, workflow-level rates (nil when no
      # terminal workflows), and average completed duration in seconds.
      def totals = data[:totals]

      # The most frequent error classes in the window, highest first, as an
      # ordered {error_class => count} hash. Scoped to the class when set.
      def top_errors(limit: 8)
        rel = ChronoForge::ErrorLog.where(created_at: @since..@now)
        rel = rel.joins(:workflow).where(ChronoForge::Workflow.table_name => {job_class: @job_class}) if @job_class
        rel.group(:error_class).order(Arel.sql("COUNT(*) DESC")).limit(limit).count
      end

      private

      def data
        @data ||= compute
      end

      def compute
        completed_by_day = scope(:completed, "completed_at").group(day("completed_at")).count
        failed_by_day = scope(:failed, "updated_at").group(day("updated_at")).count
        durations_by_day = completed_with_duration.group(day("completed_at"))
          .average(Arel.sql(duration_secs("#{table}.started_at", "#{table}.completed_at")))

        days = (completed_by_day.keys + failed_by_day.keys).uniq.sort
        buckets = days.map do |d|
          Bucket.new(
            day: d,
            completed: completed_by_day[d].to_i,
            failed: failed_by_day[d].to_i,
            avg_duration: durations_by_day[d]&.to_f&.round
          )
        end

        c = buckets.sum(&:completed)
        f = buckets.sum(&:failed)
        n = c + f
        avg = completed_with_duration.average(Arel.sql(duration_secs("#{table}.started_at", "#{table}.completed_at")))

        totals = {
          completed: c, failed: f, terminal: n,
          completion_rate: n.zero? ? nil : c.to_f / n,
          failure_rate: n.zero? ? nil : f.to_f / n,
          avg_duration: avg&.to_f&.round
        }
        {buckets: buckets, totals: totals}
      end

      # Terminal workflows of one state within the window, by the given timestamp
      # column. Optionally scoped to a single class.
      def scope(state, time_col)
        s = ChronoForge::Workflow
          .where(state: ChronoForge::Workflow.states[state])
          .where("#{table}.#{time_col}": @since..@now)
        s = s.where(job_class: @job_class) if @job_class
        s
      end

      def completed_with_duration
        scope(:completed, "completed_at").where.not(started_at: nil)
      end

      def table = ChronoForge::Workflow.table_name

      def adapter_name
        @adapter_name ||= ChronoForge::Workflow.with_connection { |c| c.adapter_name }
      end

      # A 'YYYY-MM-DD' day key for the given timestamp column.
      def day(col)
        qualified = "#{table}.#{col}"
        Arel.sql(
          case adapter_name
          when /postgres/i then "to_char(#{qualified}, 'YYYY-MM-DD')"
          when /mysql|trilogy/i then "DATE_FORMAT(#{qualified}, '%Y-%m-%d')"
          else "strftime('%Y-%m-%d', #{qualified})" # sqlite + fallback
          end
        )
      end

      # Elapsed seconds between two timestamp columns.
      def duration_secs(from, to)
        case adapter_name
        when /postgres/i then "EXTRACT(EPOCH FROM (#{to} - #{from}))"
        when /mysql|trilogy/i then "TIMESTAMPDIFF(SECOND, #{from}, #{to})"
        else "(julianday(#{to}) - julianday(#{from})) * 86400" # sqlite + fallback
        end
      end
    end
  end
end
