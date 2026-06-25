module ChronoForge
  module Dashboard
    class BaseController < ActionController::Base
      layout "chrono_forge/dashboard/application"

      protect_from_forgery with: :exception
      before_action :authenticate!

      private

      def authenticate!
        config = ChronoForge::Dashboard.config
        if config.auth_hook
          instance_exec(self, &config.auth_hook)
        elsif config.http_basic
          creds = config.http_basic
          authenticate_or_request_with_http_basic("ChronoForge") do |u, p|
            ActiveSupport::SecurityUtils.secure_compare(u, creds[:username]) &
              ActiveSupport::SecurityUtils.secure_compare(p, creds[:password])
          end
        elsif config.authentication == :none
          true
        else
          raise AuthenticationNotConfigured
        end
      end
    end
  end
end
