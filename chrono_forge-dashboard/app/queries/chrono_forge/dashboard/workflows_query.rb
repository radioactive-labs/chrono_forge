module ChronoForge
  module Dashboard
    # Keyset (cursor) pagination over workflows. Orders by primary key descending
    # (newest first) and pages with `id < cursor` / `id > cursor` rather than
    # OFFSET, and never issues a COUNT(*). Both degrade at scale; keyset stays
    # constant-cost at any depth and over any number of rows. Accepts a `base`
    # scope so it also drives bounded child lists (e.g. a branch's children).
    class WorkflowsQuery
      DEFAULT_PER = 50
      MAX_PER = 200

      def initialize(base: ChronoForge::Workflow.all, state: nil, job_class: nil, key: nil,
        created_from: nil, created_to: nil, before: nil, after: nil, per: DEFAULT_PER)
        @base = base
        @state = state.presence
        @job_class = job_class.presence
        @key = key.presence
        @created_from = created_from.presence
        @created_to = created_to.presence
        @before = before.presence&.to_i
        @after = after.presence&.to_i
        @per = per.to_i.clamp(1, MAX_PER)
      end

      def records
        load
        @records
      end

      attr_reader :per

      def has_next? # older rows remain
        load
        @has_next
      end

      def has_prev? # newer rows remain
        load
        @has_prev
      end

      def next_cursor = records.last&.id
      def prev_cursor = records.first&.id

      private

      def load
        return if @loaded
        @loaded = true
        col = "#{ChronoForge::Workflow.table_name}.id"

        if @after
          # Paging toward newer rows (Prev): ids above the cursor, ascending,
          # then flipped back to descending for display.
          rows = filtered.where("#{col} > ?", @after).order(id: :asc).limit(@per + 1).to_a
          @has_prev = rows.size > @per
          @records = rows.first(@per).reverse
          @has_next = true
        else
          scope = filtered
          scope = scope.where("#{col} < ?", @before) if @before
          rows = scope.order(id: :desc).limit(@per + 1).to_a
          @has_next = rows.size > @per
          @records = rows.first(@per)
          @has_prev = @before.present?
        end
      end

      def filtered
        s = @base
        s = s.where(state: ChronoForge::Workflow.states[@state]) if @state && ChronoForge::Workflow.states.key?(@state)
        s = s.where(job_class: @job_class) if @job_class
        s = s.where("key LIKE ?", "%#{@key}%") if @key
        s = s.where(created_at: @created_from..) if @created_from
        s = s.where(created_at: ..@created_to) if @created_to
        s
      end
    end
  end
end
