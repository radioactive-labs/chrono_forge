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

          # Validate cadence here, in the parent, so a misconfiguration fails at the
          # call site instead of deep inside the poller — where (pending * FACTOR)
          # .clamp(min, max) would raise ArgumentError, a non-transient error that
          # dead-letters BranchMergeJob and orphans the parent.
          if min_interval > max_interval
            raise ArgumentError,
              "min_interval (#{min_interval}) must be <= max_interval (#{max_interval})"
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
          # Mint a fresh fencing token and stamp it on each branch log under a row
          # lock — the read-modify-write must not clobber a concurrent poll-state
          # write from an in-flight poller. Rotating the token orphans any prior
          # poller chain (its token no longer matches), so only the chain we enqueue
          # below drives the merge. See BranchMergeJob#superseded?.
          token = SecureRandom.uuid
          ExecutionLog.where(id: branch_log_ids).find_each do |log|
            log.with_lock do
              log.update!(metadata: (log.metadata || {}).merge("poll_token" => token))
            end
          end
          BranchMergeJob.perform_later(
            @workflow.key, self.class.to_s, branch_log_ids,
            min_interval.to_i, max_interval.to_i, token
          )
        end
      end
    end
  end
end
