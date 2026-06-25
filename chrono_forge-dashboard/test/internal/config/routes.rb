Rails.application.routes.draw do
  mount ChronoForge::Dashboard::Engine => "/chrono_forge"
end
