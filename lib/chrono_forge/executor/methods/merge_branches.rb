module ChronoForge
  module Executor
    module Methods
      module MergeBranches
        # Join one or more named branches. Separate from dispatch so branches run
        # concurrently. Does one immediate check; if not done, hands off to the
        # lightweight BranchMergeJob and halts (the heavy parent is not replayed
        # per poll). Cadence clamps between min/max, scaled by pending.
        def merge_branches(*names, min_interval: 5.seconds, max_interval: 5.minutes)
          names.each do |nm|
            validate_step_name_segment!(nm)  # rejects "$"
            if nm.to_s.include?(",")
              raise InvalidStepName,
                "branch name may not contain ',' (reserved merge separator): #{nm.inspect}"
            end
          end

          names = names.map(&:to_s).uniq
          step_name = "merge$#{names.sort.join(",")}"
          log = find_or_create_execution_log!(step_name) { |l| l.started_at = Time.current }

          if log.completed?
            # Already done — remove from registry so the completion gate does not
            # see these as unmerged, then skip.
            names.each { |nm| @open_branches&.delete(nm.to_s) }
            return
          end

          branch_log_ids = names.map { |nm| open_branch!(nm)[:log_id] }

          if branches_done?(branch_log_ids)
            names.each { |nm| @open_branches&.delete(nm.to_s) }
            log.update!(state: :completed, completed_at: Time.current)
            return
          end

          enqueue_branch_merge_job(branch_log_ids, min_interval, max_interval)
          halt_execution!
        end
        alias_method :merge_branch, :merge_branches

        private

        def open_branch!(name)
          (@open_branches || {}).fetch(name.to_s) do
            raise UnknownBranchError, "no open branch named #{name.inspect} (open it with `branch #{name.inspect} do … end` first)"
          end
        end

        def branches_done?(branch_log_ids)
          branch_log_ids.all? { |id| BranchProbe.done?(id) }
        end

        def enqueue_branch_merge_job(branch_log_ids, min_interval, max_interval)
          BranchMergeJob.perform_later(
            @workflow.key, self.class.to_s, branch_log_ids,
            min_interval.to_i, max_interval.to_i
          )
        end
      end
    end
  end
end
