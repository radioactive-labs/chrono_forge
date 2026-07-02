class OrderProcessingWorkflow < ActiveJob::Base
  prepend ChronoForge::Executor

  # Fans a batch out into one child workflow per line item, then merges them back.
  # The body is never executed in the dashboard preview (the seed fabricates the
  # branch$fulfillment / merge$fulfillment logs and the child workflows); its
  # durable calls line up with those step names so the definition graph overlays a
  # real fan-out with per-state child counts.
  def perform(batch_id:)
    branch :fulfillment do
      spawn_each :order, line_items
    end
    merge_branches :fulfillment
  end
end
