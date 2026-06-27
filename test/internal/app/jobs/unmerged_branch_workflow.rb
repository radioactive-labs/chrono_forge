class UnmergedBranchWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    branch :forgotten do   # no automerge, never merged
      spawn :c, NoopChild
    end
  end
end
