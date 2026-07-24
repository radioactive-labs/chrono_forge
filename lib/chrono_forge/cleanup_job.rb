module ChronoForge
  # ActiveJob wrapper around {Cleanup} so the cleanup can be enqueued and
  # scheduled with any recurring-job mechanism (Solid Queue recurring tasks,
  # sidekiq-cron, GoodJob cron, ...).
  #
  # Arguments are plain scalars (day counts) rather than ActiveSupport::Duration
  # objects so the job can be configured from YAML/cron config files, which can
  # only carry primitive values:
  #
  #   ChronoForge::CleanupJob.perform_later(
  #     older_than_days: 90,
  #     failed_older_than_days: 180,
  #     prune_repetition_logs_older_than_days: 30
  #   )
  class CleanupJob < ActiveJob::Base
    # Deferrable housekeeping — placeable on an off-peak queue via config. Read
    # per-enqueue (see ChronoForge::Configuration#maintenance_queue) so a config change
    # takes effect without redefining the class. Defaults to :default; unlike the
    # branch-merge poller, delaying cleanup is harmless, so it is NOT latency-critical.
    queue_as { ChronoForge.config.maintenance_queue }

    def perform(older_than_days: nil, completed_older_than_days: nil, failed_older_than_days: nil,
      prune_repetition_logs_older_than_days: nil, batch_size: nil)
      options = {}
      options[:older_than] = older_than_days.to_i.days if older_than_days
      options[:completed_older_than] = completed_older_than_days.to_i.days if completed_older_than_days
      options[:failed_older_than] = failed_older_than_days.to_i.days if failed_older_than_days
      if prune_repetition_logs_older_than_days
        options[:prune_repetition_logs_older_than] = prune_repetition_logs_older_than_days.to_i.days
      end
      options[:batch_size] = batch_size.to_i if batch_size

      Cleanup.run(**options)
    end
  end
end
