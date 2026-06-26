Rails.application.configure do
  config.action_dispatch.show_exceptions = :none
  config.active_job.queue_adapter = :test

  # Sign the session cookie so flash survives a redirect in the live demo
  # (`bin/dev`). Without a secret the cookie store silently drops writes and
  # the flash toast never appears after an action.
  config.secret_key_base = "chrono_forge_dashboard_dummy_secret_key_base"
  config.session_store :cookie_store, key: "_chrono_forge_dashboard_session"
end
