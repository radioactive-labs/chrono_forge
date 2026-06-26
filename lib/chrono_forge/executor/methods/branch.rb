module ChronoForge
  module Executor
    module Methods
      module Branch
        # Opens a named branch — a durable fan-out step. Spawns inside the block
        # eagerly create + enqueue child workflows; the branch SEALS when the
        # block closes. Returns without waiting (branches are concurrent; the
        # join is a separate merge_branches / automerge).
        def branch(name, automerge: false)
          raise ArgumentError, "branch requires a block" unless block_given?
          raise ArgumentError, "branch blocks cannot be nested" if @current_branch
          validate_step_name_segment!(name)

          step_name = "branch$#{name}"
          log = find_or_create_execution_log!(step_name) { |l| l.started_at = Time.current }

          # The sealed branch log may be a readonly, id-less cache stand-in; fetch
          # the real id so the registry/merge can scope children to it.
          log_id = log.id || ExecutionLog.where(workflow: @workflow, step_name: step_name).pick(:id)
          (@open_branches ||= {})[name.to_s] = {automerge: automerge, log_id: log_id}

          # ---- THE single most important correctness/performance property ----
          # A SEALED branch skips its block ENTIRELY. The expensive source
          # enumeration in spawn_each never re-runs after sealing. Do not move
          # dispatch out from behind this guard.
          unless log.completed?
            @current_branch = {name: name.to_s, log: log}
            begin
              yield
            ensure
              @current_branch = nil
            end
            log.update!(state: :completed, completed_at: Time.current)
          end

          name
        end

        # Dispatch a single child into the current branch.
        def spawn(name, workflow_class, **kwargs)
          cb = current_branch!
          validate_step_name_segment!(name)
          child_key = "#{@workflow.key}$#{cb[:name]}$#{name}"
          dispatch_children(cb, [[child_key, workflow_class, kwargs]])
          name
        end

        # Dispatch one child per item of `source`, streamed. AR relations use
        # keyset iteration (find_in_batches start:) for constant memory; any other
        # enumerable uses an offset cursor. Items are keyed `name_{index}` by their
        # sequential position, so the source must re-enumerate identically across
        # replays. The block returns [WorkflowClass, kwargs] (or a bare class).
        def spawn_each(name, source, of: 1000)
          cb = current_branch!
          validate_step_name_segment!(name)
          cursor = (cb[:log].metadata&.dig("cursors", name.to_s)) || {}
          n = (cursor["n"] || 0)

          if source.is_a?(ActiveRecord::Relation)
            # spawn_each iterates by primary key (find_in_batches) so the stream
            # re-enumerates identically across replays. An explicit .order would
            # make iteration non-deterministic, so reject it up front with a clear
            # error rather than letting find_in_batches raise deep in the loop.
            if source.order_values.present?
              raise NotExecutableError,
                "spawn_each iterates #{source.model_name} by primary key; remove the " \
                "explicit .order(...) (or default-scope order) from the source relation"
            end
            source.find_in_batches(batch_size: of, start: cursor["pk"]) do |records|
              entries = records.map do |record|
                klass, kw = normalize_spawn(yield(record))
                # Stable per-record key: an inclusive find_in_batches re-yield of the
                # boundary record on crash-resume produces the SAME key, so insert_all
                # dedups it (idempotent). Sequential indexing would duplicate it.
                ck = "#{@workflow.key}$#{cb[:name]}$#{name}_#{record.id}"
                [ck, klass, kw]
              end
              dispatch_children(cb, entries)
              advance_cursor!(cb, name, pk: records.last.id)
            end
          else
            source.drop(n).each_slice(of) do |slice|
              entries = slice.map do |item|
                klass, kw = normalize_spawn(yield(item))
                ck = "#{@workflow.key}$#{cb[:name]}$#{name}_#{n}"
                n += 1
                [ck, klass, kw]
              end
              dispatch_children(cb, entries)
              advance_cursor!(cb, name, n: n)
            end
          end
          name
        end

        private

        def current_branch!
          @current_branch || raise(NotInBranchError, "spawn/spawn_each may only be called inside a branch block")
        end

        # Bulk-create child workflow rows then bulk-enqueue their jobs.
        # perform_all_later bypasses the class-level perform_later guard, so we
        # validate the args ourselves before enqueuing.
        def dispatch_children(cb, entries)
          return if entries.empty?
          now = Time.current
          rows = entries.map do |child_key, klass, kwargs|
            validate_child_enqueue!(child_key, kwargs)
            {
              key: child_key, job_class: klass.to_s,
              kwargs: kwargs, options: {}, context: {},
              state: Workflow.states[:idle],
              parent_execution_log_id: cb[:log].id,
              created_at: now, updated_at: now
            }
          end
          # On-conflict-ignore makes re-dispatch (crash recovery) idempotent.
          Workflow.insert_all(rows, unique_by: [:job_class, :key])
          jobs = entries.map { |child_key, klass, kwargs| klass.new(child_key, **kwargs) }
          ActiveJob.perform_all_later(jobs)
        end

        def validate_child_enqueue!(child_key, kwargs)
          unless child_key.is_a?(String)
            raise ArgumentError, "child key must be a String (got #{child_key.inspect})"
          end
          reserved = kwargs.keys.map(&:to_sym) & RESERVED_KWARGS
          if reserved.any?
            raise ArgumentError, "#{reserved.join(", ")} are reserved ChronoForge keywords"
          end
        end

        # Advance (and persist) a spawn_each cursor on the branch log.
        # `n` is the running item index; `pk` is the AR keyset position (nil for
        # plain enumerables). (Used by spawn_each in a later task.)
        def advance_cursor!(cb, spawn_name, n: nil, pk: nil)
          meta = cb[:log].metadata || {}
          cursors = meta["cursors"] || {}
          entry = cursors[spawn_name.to_s] || {}
          entry["n"] = n unless n.nil?
          entry["pk"] = pk unless pk.nil?
          cursors[spawn_name.to_s] = entry
          meta["cursors"] = cursors
          cb[:log].update!(metadata: meta)
        end

        # Normalize a spawn_each block return: [Klass, kwargs] or a bare Klass.
        def normalize_spawn(result)
          klass, kwargs = Array(result)
          unless klass.is_a?(Module)
            raise ArgumentError,
              "spawn_each block must return a workflow class or [class, kwargs] (got #{result.inspect})"
          end
          [klass, kwargs || {}]
        end
      end
    end
  end
end
