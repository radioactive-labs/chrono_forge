class SingleSpawnWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    branch :grp, automerge: true do
      spawn :child, NoopChild, foo: "bar"
    end
  end
end
