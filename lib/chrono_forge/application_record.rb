# frozen_string_literal: true

module ChronoForge
  # Abstract base class for all ChronoForge models.
  #
  # Multi-database support: point every ChronoForge table at a separate
  # database instead of the app's primary connection. The host sets either
  # config.database (a database name; the common case) or config.connects_to
  # (a raw hash for custom roles/shards, which wins if both are set). Read
  # once here at class load: initializers run before these models are first
  # referenced (Zeitwerk autoloads them lazily), so the setting is in place.
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    # This runs once, at first class load, so it is only coverable by tests
    # that boot the app with the config already set — see test/multi_db/,
    # where each file runs in its own process for exactly that reason.
    if ChronoForge.config.connects_to
      connects_to(**ChronoForge.config.connects_to)
    elsif (db = ChronoForge.config.database)
      connects_to database: {writing: db, reading: db}
    end
  end
end
