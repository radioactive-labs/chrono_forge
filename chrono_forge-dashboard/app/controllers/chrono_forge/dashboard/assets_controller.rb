module ChronoForge
  module Dashboard
    class AssetsController < BaseController
      skip_before_action :authenticate!
      skip_forgery_protection

      TYPES = {
        "dashboard.css" => "text/css",
        "dashboard.js" => "application/javascript",
        "mermaid.min.js" => "application/javascript"
      }.freeze
      ROOT = ChronoForge::Dashboard::Engine.root.join("app/assets/chrono_forge/dashboard")

      def show
        file = params[:file]
        type = TYPES[file] or return head(:not_found)
        path = ROOT.join(file)
        return head(:not_found) unless path.file?

        response.set_header("Cache-Control", "public, max-age=31536000, immutable")
        send_file path, type: type, disposition: "inline"
      end
    end
  end
end
