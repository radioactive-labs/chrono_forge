class SpawnEachWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform(of: 1000)
    branch :grp, automerge: true do
      spawn_each :items, User.all, of: of do |user|
        [NoopChild, {user_id: user.id}]
      end
    end
  end
end
