# frozen_string_literal: true

require "zeitwerk"
require "active_record"
require "active_job"

module Chronoforge
  Loader = Zeitwerk::Loader.for_gem.tap do |loader|
    loader.ignore("#{__dir__}/generators")
    loader.setup
  end

  class Error < StandardError; end
end
