require "chrono_forge"
require "chrono_forge/dashboard/version"
require "chrono_forge/dashboard/configuration"
require "chrono_forge/dashboard/engine"

module ChronoForge
  module Dashboard
    class << self
      def config = (@config ||= Configuration.new)
      def configure = yield(config)
      def reset_configuration! = @config = Configuration.new
    end
  end
end
