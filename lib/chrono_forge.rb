# frozen_string_literal: true

require_relative "chrono_forge/version"

require "zeitwerk"
require "active_support/core_ext/object/blank"

module Chronoforge
  Loader = Zeitwerk::Loader.new.tap do |loader|
    loader.tag = File.basename(__FILE__, ".rb")
    loader.ignore("#{__dir__}/generators")
    loader.setup
  end

  class Error < StandardError; end
end
