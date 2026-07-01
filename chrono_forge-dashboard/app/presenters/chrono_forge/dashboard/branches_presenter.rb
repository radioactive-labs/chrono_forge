module ChronoForge
  module Dashboard
    # A workflow's branches for its detail page. Loads only the coordination logs
    # (branch$<name> and merge$<names>) — a tiny set — and derives each branch's
    # merge state from the merge logs (the core doesn't persist a "merged" flag).
    class BranchesPresenter
      # One merge join (a merge$<names> log = a BranchMergeJob's durable target).
      # state: :merging (pending — a poller is joining) | :merged (completed).
      # The poll fields are the BranchMergeJob's observable cadence (it stamps them
      # on the target branch logs each pass): when it last checked, when it's
      # scheduled to check next, and how many times it has polled.
      Merge = Struct.new(:names, :state, :started_at, :last_polled_at, :next_poll_at, :polls, :rate, :eta_seconds) do
        def merging? = state == :merging

        # A next check scheduled in the past while still merging means the poller
        # was dropped (or is overdue) — the join is stuck until it's re-armed.
        def poll_overdue? = merging? && next_poll_at && next_poll_at.past?

        # Throughput is a live gauge — only meaningful while merging and actually
        # draining (rate 0.0 means idle; a merged join has no live rate).
        def throughput? = merging? && rate.to_f > 0
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
        @merges ||= merge_logs.map { |log|
          names = StepNameParser.parse(log.step_name).name.split(",")
          poll = merge_poll(names)
          Merge.new(
            names,
            log.completed? ? :merged : :merging,
            log.started_at,
            parse_time(poll&.dig("last_polled_at")),
            parse_time(poll&.dig("next_poll_at")),
            poll&.dig("polls"),
            poll&.dig("rate"),
            poll&.dig("eta_seconds")
          )
        }.sort_by { |m| [m.merging? ? 0 : 1, m.started_at || Time.current] }
      end

      private

      # Freshest poll state across a merge's target branch logs. BranchMergeJob
      # stamps identical state on every target branch each pass, so any one works;
      # take the latest by last_polled_at to be safe with multi-branch merges.
      def merge_poll(names)
        names.filter_map { |nm| branch_poll_by_name[nm] }.max_by { |p| p["last_polled_at"].to_s }
      end

      def branch_poll_by_name
        @branch_poll_by_name ||= branch_logs.each_with_object({}) do |log, h|
          h[StepNameParser.parse(log.step_name).name] = log.metadata&.dig("poll")
        end
      end

      def parse_time(value)
        return nil if value.blank?
        value.is_a?(Time) ? value : Time.zone.parse(value.to_s)
      end

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
