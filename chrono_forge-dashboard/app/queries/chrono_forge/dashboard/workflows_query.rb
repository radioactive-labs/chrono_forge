module ChronoForge
  module Dashboard
    class WorkflowsQuery
      DEFAULT_PER = 50

      def initialize(state: nil, job_class: nil, key: nil, created_from: nil, created_to: nil, page: 1, per: DEFAULT_PER)
        @state = state.presence
        @job_class = job_class.presence
        @key = key.presence
        @created_from = created_from.presence
        @created_to = created_to.presence
        @page = [page.to_i, 1].max
        @per = [per.to_i, 1].max
      end

      def results = scope.order(created_at: :desc).limit(@per).offset((@page - 1) * @per)

      def total_count = scope.count

      attr_reader :page

      attr_reader :per

      private

      def scope
        s = ChronoForge::Workflow.all
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
