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

  def self.ApplicationRecord = defined?(::ApplicationRecord) ? ::ApplicationRecord : ActiveRecord::Base

  # Engine configuration (see ChronoForge::Configuration).
  #   ChronoForge.configure { |c| c.branch_merge_queue = :chrono_forge_pollers }
  def self.config = @config ||= Configuration.new

  def self.configure = yield(config)

  def self.reset_configuration! = @config = Configuration.new
end
