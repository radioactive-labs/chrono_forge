class EnumSpawnWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform(items:, of: 1000)
    branch :grp, automerge: true do
      spawn_each :things, items, of: of do |item|
        [NoopChild, {value: item}]
      end
    end
  end
end
