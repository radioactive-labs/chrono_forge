class ReplayBranchWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    branch :items, automerge: true do
      spawn_each :item, User.all do |u|
        [NoopChild, {user_id: u.id}]
      end
    end
    durably_execute :finalize
  end

  private

  def finalize
    context["finalized"] = true
  end
end
