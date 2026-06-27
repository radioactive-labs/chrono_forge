class NestingChild < WorkflowJob
  prepend ChronoForge::Executor

  def perform(**)
    branch :sub, automerge: true do
      spawn :gc, NoopChild
    end
  end
end
