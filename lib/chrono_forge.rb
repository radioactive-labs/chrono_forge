# frozen_string_literal: true

require "zeitwerk"
require "active_record"
require "active_job"

module ChronoForge
  Loader = Zeitwerk::Loader.for_gem.tap do |loader|
    loader.ignore("#{__dir__}/generators")
    loader.setup
  end

  class Error < StandardError; end

  # Engine configuration (see ChronoForge::Configuration).
  #   ChronoForge.configure { |c| c.branch_merge_queue = :chrono_forge_pollers }
  def self.config = @config ||= Configuration.new

  def self.configure = yield(config)

  # Primary key type for ChronoForge's own tables. Explicit config wins;
  # otherwise respect the app's global generators setting; otherwise Rails'
  # default (bigint).
  def self.primary_key_type
    config.primary_key_type || app_generators_primary_key_type || :bigint
  end

  # The host app's config.generators primary_key_type, when running inside a
  # booted Rails app (the gem itself does not depend on railties).
  def self.app_generators_primary_key_type
    return unless defined?(Rails) && Rails.application

    Rails.application.config.generators.options.dig(:active_record, :primary_key_type)
  end
  private_class_method :app_generators_primary_key_type

  def self.reset_configuration! = @config = Configuration.new
end
