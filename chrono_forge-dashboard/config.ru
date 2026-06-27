# Dev-only boot for driving the dashboard in a browser. Not part of the gem.
ENV["RAILS_ENV"] ||= "test"

require "active_job/railtie"
require "chrono_forge/dashboard"
require "combustion"

Combustion.path = "test/internal"
Combustion.initialize! :active_record, :active_job, :action_controller

ChronoForge::Dashboard.configure do |c|
  c.authentication = :none
  c.polling_interval = 0 # stable for screenshots
end

W = ChronoForge::Workflow
E = ChronoForge::ExecutionLog
L = ChronoForge::ErrorLog

def estate(s) = ChronoForge::ExecutionLog.states[s]

W.delete_all
E.delete_all
L.delete_all

# Failed order with an error log and a runtime-branching context
wf = W.create!(key: "order-1001", job_class: "OrderWorkflow", state: W.states[:failed],
  context: {"amount" => 4999, "currency" => "GHS", "requires_compliance" => true, "line_item_ids" => [1, 2, 3]},
  kwargs: {"order_id" => "order-1001"}, options: {}, started_at: 20.minutes.ago)
E.create!(workflow: wf, step_name: "wait_until$payment_confirmed?", state: estate(:completed), attempts: 2, started_at: 19.minutes.ago, completed_at: 18.minutes.ago)
E.create!(workflow: wf, step_name: "durably_execute$validate_order", state: estate(:completed), attempts: 1, started_at: 18.minutes.ago, completed_at: 18.minutes.ago)
E.create!(workflow: wf, step_name: "durably_execute$charge_card", state: estate(:failed), attempts: 3, started_at: 17.minutes.ago, error_class: "PaymentDeclinedError")
L.create!(workflow: wf, step_name: "durably_execute$charge_card", attempt: 3, error_class: "PaymentDeclinedError",
  error_message: "card declined: insufficient funds", backtrace: "app/services/payments.rb:42\napp/workflows/order.rb:18")

# Workflow-level failure: an uncaught error in perform records a nil-step error
# log linked from a $workflow_failure$<id> marker. The dashboard attaches it to
# the marker so the failure isn't invisible.
wf6 = W.create!(key: "import-88", job_class: "OrderWorkflow", state: W.states[:failed],
  context: {"batch" => 88}, kwargs: {"batch_id" => 88}, options: {}, started_at: 2.hours.ago)
E.create!(workflow: wf6, step_name: "durably_execute$import_rows", state: estate(:pending),
  attempts: 1, started_at: 2.hours.ago, last_executed_at: 90.minutes.ago)
imp_err = L.create!(workflow: wf6, step_name: nil, attempt: 1,
  error_class: "ActiveRecord::Deadlocked", error_message: "deadlock detected during batch import",
  backtrace: "app/workflows/import.rb:14\nlib/chrono_forge/executor.rb:124")
E.create!(workflow: wf6, step_name: "$workflow_failure$#{imp_err.id}", state: estate(:completed),
  attempts: 1, started_at: 90.minutes.ago, completed_at: 90.minutes.ago, metadata: {"error_log_id" => imp_err.id})

# Idle, waiting a long time (flagged in wait-states view)
wf2 = W.create!(key: "signup-77", job_class: "OrderWorkflow", state: W.states[:idle],
  context: {"user_id" => 77}, kwargs: {}, options: {}, started_at: 5.hours.ago)
E.create!(workflow: wf2, step_name: "wait_until$kyc_approved?", state: estate(:pending), attempts: 1,
  started_at: 5.hours.ago, last_executed_at: 5.hours.ago, metadata: {"timeout_at" => 2.hours.from_now.iso8601})

# Idle on a continue_if (event wait) whose webhook never arrived — the silent
# stall the wait-states "oldest event wait" panel exists to surface.
wf2b = W.create!(key: "refund-204", job_class: "RefundWorkflow", state: W.states[:idle],
  context: {"charge_id" => "ch_204"}, kwargs: {}, options: {}, started_at: 3.days.ago)
E.create!(workflow: wf2b, step_name: "continue_if$gateway_webhook_received", state: estate(:pending),
  attempts: 1, started_at: 3.days.ago, last_executed_at: 3.days.ago, metadata: {})

# Completed
wf3 = W.create!(key: "order-1000", job_class: "OrderWorkflow", state: W.states[:completed],
  context: {"amount" => 1200}, kwargs: {}, options: {}, started_at: 1.day.ago, completed_at: 1.day.ago)
E.create!(workflow: wf3, step_name: "durably_execute$process", state: estate(:completed), attempts: 1, started_at: 1.day.ago, completed_at: 1.day.ago)
E.create!(workflow: wf3, step_name: "$workflow_completion$", state: estate(:completed), attempts: 1, started_at: 1.day.ago, completed_at: 1.day.ago)

# Running with a durably_repeat (3 completed runs + 1 timeout)
wf4 = W.create!(key: "newsletter-9", job_class: "OrderWorkflow", state: W.states[:running],
  context: {}, kwargs: {}, options: {}, started_at: 2.days.ago, locked_at: 2.minutes.ago, locked_by: "job-abc")
E.create!(workflow: wf4, step_name: "durably_repeat$send_digest", state: estate(:pending), attempts: 5,
  started_at: 2.days.ago, metadata: {"last_execution_at" => 3.hours.ago.iso8601})
[3.days.ago, 2.days.ago, 1.day.ago].each_with_index do |t, i|
  E.create!(workflow: wf4, step_name: "durably_repeat$send_digest$#{t.to_i}", state: estate(:completed),
    attempts: 1, started_at: t, completed_at: t + (10 + i * 5))
end
E.create!(workflow: wf4, step_name: "durably_repeat$send_digest$#{12.hours.ago.to_i}", state: estate(:failed),
  attempts: 1, error_class: "TimeoutError", started_at: 12.hours.ago, completed_at: 12.hours.ago)
# Fast-forward catch-up: one summary row collapsing a long downtime gap into N
# skipped ticks (instead of N per-tick tombstones).
ff_from = 20.hours.ago
ff_to = 13.hours.ago
E.create!(workflow: wf4, step_name: "durably_repeat$send_digest$#{ff_to.to_i}", state: estate(:failed),
  attempts: 1, error_class: "TimeoutError", error_message: "Fast-forwarded 84 expired tick(s)",
  started_at: 13.hours.ago, completed_at: 13.hours.ago,
  metadata: {"fast_forwarded" => 84, "from" => ff_from.iso8601, "to" => ff_to.iso8601,
             "scheduled_for" => ff_to.iso8601})

# Stalled — a step exhausted its retries; the workflow halted and is unlocked
wf5 = W.create!(key: "payout-3", job_class: "OrderWorkflow", state: W.states[:stalled],
  context: {"amount" => 8000}, kwargs: {"payout_id" => "payout-3"}, options: {},
  started_at: 1.hour.ago)
E.create!(workflow: wf5, step_name: "durably_execute$disburse_funds", state: estate(:pending),
  attempts: 2, started_at: 50.minutes.ago, last_executed_at: 50.minutes.ago)
L.create!(workflow: wf5, step_name: "durably_execute$disburse_funds", attempt: 2,
  error_class: "Net::ReadTimeout", error_message: "execution expired while calling disbursement API",
  backtrace: "app/services/disbursements.rb:88\napp/workflows/payout.rb:25")

# Kitchen sink — exercises every step kind and state, all context field types,
# multi-attempt inline errors with backtraces, and a periodic task with a late
# run + a tombstone. Stalled on a failed charge so the failed step is current.
ks = W.create!(key: "kitchensink-1", job_class: "KitchenSinkWorkflow", state: W.states[:stalled],
  context: {
    "amount" => 49999, "currency" => "USD", "fee_rate" => 0.029,
    "expedited" => true, "gift_wrap" => false, "coupon_code" => nil,
    "line_item_ids" => [101, 102, 103],
    "customer" => {"id" => 77, "tier" => "gold", "vip" => true},
    "tags" => ["priority", "international", "insured"],
    "notes" => "Signature on delivery + gift receipt; flagged for manual fraud review (billing country mismatch)."
  },
  kwargs: {"order_id" => "ks-1", "max_attempts" => 5, "dry_run" => false, "channel" => "web"},
  options: {}, started_at: 2.hours.ago)

E.create!(workflow: ks, step_name: "durably_execute$validate_input", state: estate(:completed),
  attempts: 1, started_at: 2.hours.ago, completed_at: 2.hours.ago + 2)
E.create!(workflow: ks, step_name: "wait_until$inventory_available?", state: estate(:completed),
  attempts: 3, started_at: 115.minutes.ago, completed_at: 108.minutes.ago,
  last_executed_at: 108.minutes.ago, metadata: {"timeout_at" => 90.minutes.ago.iso8601})
E.create!(workflow: ks, step_name: "durably_execute$reserve_stock", state: estate(:completed),
  attempts: 1, started_at: 107.minutes.ago, completed_at: 107.minutes.ago + 3)
# Fixed wait (sleep until a time) — carries its resume time in metadata
E.create!(workflow: ks, step_name: "wait$settlement_window", state: estate(:completed),
  attempts: 1, started_at: 106.minutes.ago, completed_at: 102.minutes.ago,
  metadata: {"wait_until" => 102.minutes.ago.iso8601})

# Periodic reconcile: coordination + runs (one on time, one late, one tombstone)
E.create!(workflow: ks, step_name: "durably_repeat$reconcile_ledger", state: estate(:pending),
  attempts: 4, started_at: 100.minutes.ago, metadata: {"last_execution_at" => 30.minutes.ago.iso8601})
[[90.minutes.ago, 4], [60.minutes.ago, 135]].each do |sched, late|
  ts = sched.to_i
  E.create!(workflow: ks, step_name: "durably_repeat$reconcile_ledger$#{ts}", state: estate(:completed),
    attempts: 1, started_at: Time.zone.at(ts + late), completed_at: Time.zone.at(ts + late + 3))
end
tomb = 30.minutes.ago.to_i
E.create!(workflow: ks, step_name: "durably_repeat$reconcile_ledger$#{tomb}", state: estate(:failed),
  attempts: 1, error_class: "TimeoutError", started_at: Time.zone.at(tomb + 30), completed_at: Time.zone.at(tomb + 30))

# Event wait (continue_if) still pending — no timeout, waits on a webhook
E.create!(workflow: ks, step_name: "continue_if$fraud_review_cleared", state: estate(:pending),
  attempts: 1, started_at: 50.minutes.ago, last_executed_at: 50.minutes.ago, metadata: {})

# Failed execute with two inline errors across attempts (the stall cause)
E.create!(workflow: ks, step_name: "durably_execute$charge_payment", state: estate(:failed),
  attempts: 3, started_at: 45.minutes.ago, error_class: "Stripe::RateLimitError")
L.create!(workflow: ks, step_name: "durably_execute$charge_payment", attempt: 1,
  error_class: "Stripe::CardError", error_message: "Your card was declined (insufficient_funds).",
  backtrace: "app/services/payments.rb:42:in `charge'\napp/workflows/kitchen_sink.rb:31:in `block in perform'\nlib/chrono_forge/executor.rb:124:in `call'")
L.create!(workflow: ks, step_name: "durably_execute$charge_payment", attempt: 2,
  error_class: "Stripe::RateLimitError", error_message: "Too many requests; backing off before retry.",
  backtrace: "app/services/payments.rb:51:in `charge'\napp/workflows/kitchen_sink.rb:31:in `block in perform'")

# Unknown/custom step kind renders gracefully
E.create!(workflow: ks, step_name: "legacy_custom_marker", state: estate(:completed),
  attempts: 1, started_at: 44.minutes.ago, completed_at: 44.minutes.ago + 1)

run Combustion::Application
