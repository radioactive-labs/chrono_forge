class KitchenSinkWorkflow < ActiveJob::Base
  prepend ChronoForge::Executor

  # A representative workflow that exercises most durable primitives, so the
  # Definition graph has something rich to draw. The body is never executed in the
  # dashboard preview (the seed fabricates the logs); its durable calls line up
  # with those seeded step names so the graph overlays a real, mixed-status run.
  def perform(order_id:, max_attempts: 5, dry_run: false, channel: "web")
    durably_execute :validate_input
    wait_until :inventory_available?
    durably_execute :reserve_stock

    if context["expedited"]
      wait 1.hour, "settlement_window"
    end

    durably_repeat :reconcile_ledger, every: 15.minutes, till: :ledger_balanced?, timeout: 1.day
    continue_if :fraud_review_cleared

    durably_execute :charge_payment
    durably_execute :capture_funds
  end
end
