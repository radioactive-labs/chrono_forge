require "chrono_forge"
require "chrono_forge/dashboard/version"
require "chrono_forge/dashboard/configuration"
require "chrono_forge/dashboard/engine"
require "chrono_forge/dashboard/step_name_parser"

module ChronoForge
  module Dashboard
    ASSET_ROOT = "app/assets/chrono_forge/dashboard"

    class << self
      def config = (@config ||= Configuration.new)
      def configure = yield(config)
      def reset_configuration! = @config = Configuration.new

      # Short content digest of a shipped asset, used to cache-bust the served
      # CSS/JS so a gem upgrade (or a local rebuild) is picked up despite the
      # long immutable cache header. Memoized; computed once per boot.
      def asset_digest(file)
        @asset_digests ||= {}
        @asset_digests[file] ||= begin
          require "digest"
          Digest::SHA256.file(Engine.root.join(ASSET_ROOT, file)).hexdigest[0, 12]
        rescue
          VERSION
        end
      end
    end
  end
end
