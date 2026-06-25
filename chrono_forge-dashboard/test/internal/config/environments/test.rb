Rails.application.configure do
  config.action_dispatch.show_exceptions = :none
  config.active_job.queue_adapter = :test
end
