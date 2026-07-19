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

    # The connects_to settings implied by the configuration, or nil when
    # ChronoForge stays on the app's primary connection. A method rather than
    # inline logic below so the derivation is testable without reconnecting.
    def self.connects_to_settings(config = ChronoForge.config)
      if config.connects_to
        config.connects_to
      elsif config.database
        {database: {writing: config.database, reading: config.database}}
      end
    end

    if (settings = connects_to_settings)
      connects_to(**settings)
    end
  end
end
