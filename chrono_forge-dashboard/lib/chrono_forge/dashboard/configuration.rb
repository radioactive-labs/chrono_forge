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
      attr_accessor :polling_interval, :polling_interval_options, :page_size, :long_wait_threshold
      # Global default and per-workflow-class overrides (seconds) for flagging a
      # running workflow that has been going too long.
      attr_accessor :long_run_threshold, :long_run_thresholds

      def initialize
        @http_basic = nil
        @authentication = nil
        @auth_hook = nil
        @polling_interval = 15
        # Selectable auto-refresh intervals (seconds; 0 = off) for the nav control.
        @polling_interval_options = [0, 5, 10, 15, 30, 60, 300]
        @page_size = 50
        @long_wait_threshold = 3600
        @long_run_threshold = 3600
        @long_run_thresholds = {}
      end

      def authenticate(&block) = @auth_hook = block

      # Seconds a running workflow of this class may run before it's flagged as
      # long-running. A per-class override wins over the global default; an
      # explicit nil (or 0) opts the class out entirely.
      def long_run_threshold_for(job_class)
        long_run_thresholds.fetch(job_class, long_run_threshold)
      end
    end
  end
end
