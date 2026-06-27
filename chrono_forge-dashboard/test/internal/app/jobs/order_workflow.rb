class OrderWorkflow < ActiveJob::Base
  prepend ChronoForge::Executor

  def perform(**)
  end
end
