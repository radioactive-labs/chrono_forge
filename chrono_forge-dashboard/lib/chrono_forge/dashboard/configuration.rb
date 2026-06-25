module ChronoForge
  module Dashboard
    class AuthenticationNotConfigured < StandardError
      MESSAGE = <<~MSG.freeze
        ChronoForge::Dashboard has no authentication configured. Do one of:
          - ChronoForge::Dashboard.configure { |c| c.http_basic = { username:, password: } }
          - ChronoForge::Dashboard.configure { |c| c.authenticate { |controller| ... } }
          - ChronoForge::Dashboard.configure { |c| c.authentication = :none }  # then guard the mount with your own routing constraint
      MSG
      def initialize(msg = MESSAGE) = super
    end

    class Configuration
      attr_accessor :http_basic, :authentication
      attr_reader :auth_hook
      attr_accessor :polling_interval, :page_size, :long_wait_threshold

      def initialize
        @http_basic = nil
        @authentication = nil
        @auth_hook = nil
        @polling_interval = 5
        @page_size = 50
        @long_wait_threshold = 3600
      end

      def authenticate(&block) = @auth_hook = block
    end
  end
end
