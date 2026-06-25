require "rails/engine"

module ChronoForge
  module Dashboard
    class Engine < ::Rails::Engine
      isolate_namespace ChronoForge::Dashboard
    end
  end
end
