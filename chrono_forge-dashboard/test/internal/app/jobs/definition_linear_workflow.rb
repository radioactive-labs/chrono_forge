class DefinitionLinearWorkflow < ActiveJob::Base
  prepend ChronoForge::Executor

  # A statically analyzable perform: DefinitionAnalyzer reads this source text
  # (via Prism); the body is never executed in the dashboard test suite.
  def perform(**)
    durably_execute :charge_card
    wait_until :funds_cleared
    durably_execute :ship
  end
end
