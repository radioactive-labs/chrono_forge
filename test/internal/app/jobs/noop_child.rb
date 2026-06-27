class NoopChild < WorkflowJob
  prepend ChronoForge::Executor

  def perform(**)
    durably_execute :noop
  end

  private

  def noop = nil
end
