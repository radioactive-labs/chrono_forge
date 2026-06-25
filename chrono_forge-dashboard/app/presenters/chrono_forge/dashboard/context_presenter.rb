module ChronoForge
  module Dashboard
    class ContextPresenter
      def initialize(workflow) = @workflow = workflow

      def nodes
        context.map { |k, v| { key: k, value: v, type: v.class.name, bytes: v.to_json.bytesize } }
      end

      def byte_size = context.to_json.bytesize

      private

      def context = @workflow.context || {}
    end
  end
end
