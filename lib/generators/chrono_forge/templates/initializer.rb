ChronoForge.configure do |config|
  # ActiveJob queue for the branch-merge poller (BranchMergeJob). For large
  # fan-outs, point this at a dedicated queue with its own worker so the
  # poller is not starved behind the branch's own children.
  # config.branch_merge_queue = :default

  # ActiveJob queue for deferrable housekeeping (CleanupJob). Unlike the poller
  # above, delaying cleanup is harmless — set this only to push pruning onto an
  # off-peak queue.
  # config.maintenance_queue = :default

  # How long a single workflow pass may hold its lock before another job may
  # steal it (the assumed maximum duration of one execution pass).
  # config.max_duration = 10.minutes

  # Age past which a workflow still in :running is treated as stranded and
  # re-enqueued by ChronoForge::Workflow.reap_stalled. Defaults to 3x max_duration.
  # config.reap_stale_after = 30.minutes

  # Primary key type for ChronoForge's own tables.
  # config.primary_key_type = nil # nil = auto-detect (app's generators setting, else :bigint); set :uuid etc. to force

  # Multi-database: keep ChronoForge's tables in their own database. Set this
  # to a database name from config/database.yml and ChronoForge routes all its
  # models and migrations there. `bin/rails g chrono_forge:install --database=NAME`
  # sets this for you; a later `chrono_forge:upgrade` run reads it so new
  # migrations still land in db/NAME_migrate. nil (default) uses the primary
  # connection.
  # config.database = :chrono_forge
  #
  # Advanced: for custom roles/shards, pass a hash straight to Rails'
  # connects_to. It wins over config.database for the connection (set
  # config.database too so the generators know where to install migrations).
  # config.connects_to = { database: { writing: :chrono_forge, reading: :chrono_forge } }
end
