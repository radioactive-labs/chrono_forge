class NestingParentWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    branch :top, automerge: true do
      spawn :c, NestingChild
    end
  end
end
