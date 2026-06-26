class TwoBranchWorkflow < WorkflowJob
  prepend ChronoForge::Executor

  def perform
    branch :a do
      spawn :one, NoopChild
    end
    branch :b do
      spawn :two, NoopChild
    end
    merge_branches :a, :b
    durably_execute :finalize
  end

  private

  def finalize
    context["finalized"] = true
  end
end
