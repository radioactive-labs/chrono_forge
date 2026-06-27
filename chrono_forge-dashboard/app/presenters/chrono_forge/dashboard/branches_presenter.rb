module ChronoForge
  module Dashboard
    # A workflow's branches for its detail page. Loads only the coordination logs
    # (branch$<name> and merge$<names>) — a tiny set — and derives each branch's
    # merge state from the merge logs (the core doesn't persist a "merged" flag).
    class BranchesPresenter
      # One merge join (a merge$<names> log = a BranchMergeJob's durable target).
      # state: :merging (pending — a poller is joining) | :merged (completed).
      Merge = Struct.new(:names, :state, :started_at) do
        def merging? = state == :merging
      end

      def initialize(workflow) = @workflow = workflow

      def any? = branch_logs.any?

      def branches
        @branches ||= branch_logs
          .sort_by(&:step_name)
          .map { |log| BranchPresenter.new(log, merge_states[StepNameParser.parse(log.step_name).name]) }
      end

      # The merge joins on this workflow, in-progress first. A long-pending merge
      # with no blocked children is the sign of a dropped BranchMergeJob poller.
      def merges
        @merges ||= merge_logs
          .map { |log| Merge.new(StepNameParser.parse(log.step_name).name.split(","), log.completed? ? :merged : :merging, log.started_at) }
          .sort_by { |m| [m.merging? ? 0 : 1, m.started_at || Time.current] }
      end

      private

      def coordination_logs
        d = StepNameParser::DELIM
        @coordination_logs ||= @workflow.execution_logs
          .where("step_name LIKE ? OR step_name LIKE ?", "branch#{d}%", "merge#{d}%")
          .to_a
      end

      def branch_logs
        coordination_logs.select { |l| StepNameParser.parse(l.step_name).kind == :branch }
      end

      def merge_logs
        coordination_logs.select { |l| StepNameParser.parse(l.step_name).kind == :merge }
      end

      # branch name => :merged (merge log completed) | :merging (pending). A merge
      # log covers one or more comma-joined branch names; "merged" wins if a name
      # appears in both a completed and a pending merge.
      def merge_states
        @merge_states ||= merge_logs
          .each_with_object({}) do |log, map|
            state = log.completed? ? :merged : :merging
            StepNameParser.parse(log.step_name).name.split(",").each do |nm|
              map[nm] = state unless map[nm] == :merged
            end
          end
      end
    end
  end
end
