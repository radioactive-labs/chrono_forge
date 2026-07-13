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

# --- Bulk throughput backfill (Overview) -------------------------------------
# A realistic processed-volume spread across classes so the Overview reads like a
# live fleet, not a toy. Bulk-inserted (no callbacks) FIRST so these rows take the
# lowest ids and stay buried behind the crafted fixtures below in the id-desc list
# (and off page 1 of every list view). Backdated 40–160 days, so they also fall
# outside the 30d analytics window, off Waiting, and off Repetitions. In-flight
# rows are idle (never running), so none register as stranded. Only the totals —
# the Overview and the workflow-list stats strip — count them.
bulk_now = Time.current
bulk_plan = {
  "OrderWorkflow" => {completed: 1240, idle: 58, failed: 6, stalled: 2},
  "OrderProcessingWorkflow" => {completed: 430, idle: 44, failed: 4, stalled: 1},
  "RefundWorkflow" => {completed: 185, idle: 12, failed: 2, stalled: 1},
  "ScheduledPaymentRecurrenceWorkflow" => {completed: 96, idle: 22, failed: 1, stalled: 1},
  "KitchenSinkWorkflow" => {completed: 14, idle: 3, failed: 3, stalled: 1}
}
# Realistic per-class key prefixes (offset well past the crafted fixtures' keys)
# so the backfill reads like real history if a viewer pages down into it.
bulk_prefix = {
  "OrderWorkflow" => "order",
  "OrderProcessingWorkflow" => "batch",
  "RefundWorkflow" => "refund",
  "ScheduledPaymentRecurrenceWorkflow" => "spr",
  "KitchenSinkWorkflow" => "recon"
}
bulk_rows = []
bulk_seq = 0
bulk_plan.each do |klass, states|
  states.each do |state_sym, n|
    n.times do
      bulk_seq += 1
      created = bulk_now - (40 + (bulk_seq % 120)).days
      bulk_rows << {
        key: "#{bulk_prefix.fetch(klass)}-#{10000 + bulk_seq}",
        job_class: klass, state: W.states[state_sym],
        context: {}, kwargs: {}, options: {},
        started_at: created, completed_at: ((state_sym == :completed) ? created + 40 : nil),
        created_at: created, updated_at: created
      }
    end
  end
end
bulk_rows.each_slice(500) { |batch| W.insert_all(batch) }

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

# Fan-out parent parked on a branch merge with blocked children (branches feature)
fo = W.create!(key: "batch-7", job_class: "OrderProcessingWorkflow", state: W.states[:idle],
  context: {"batch_id" => 7}, kwargs: {"batch_id" => 7}, options: {}, started_at: 30.minutes.ago)
fo_branch = E.create!(workflow: fo, step_name: "branch$fulfillment", state: estate(:completed),
  attempts: 1, started_at: 30.minutes.ago, completed_at: 29.minutes.ago,
  # Poll state stamped by BranchMergeJob; next_poll_at long past = dropped poller.
  metadata: {"poll" => {"last_polled_at" => 65.minutes.ago.iso8601, "next_poll_at" => 60.minutes.ago.iso8601,
                        "pending" => 2, "sealed" => true, "polls" => 9}})
E.create!(workflow: fo, step_name: "merge$fulfillment", state: estate(:pending), attempts: 1, started_at: 29.minutes.ago)
4.times do |i|
  W.create!(key: "batch-7$fulfillment$order_#{i}", job_class: "OrderWorkflow", state: W.states[:completed],
    context: {}, kwargs: {}, options: {}, started_at: 29.minutes.ago, completed_at: 28.minutes.ago, parent_execution_log_id: fo_branch.id)
end
W.create!(key: "batch-7$fulfillment$order_98", job_class: "OrderWorkflow", state: W.states[:failed],
  context: {"reason" => "card_declined"}, kwargs: {}, options: {}, started_at: 28.minutes.ago, parent_execution_log_id: fo_branch.id)
W.create!(key: "batch-7$fulfillment$order_99", job_class: "OrderWorkflow", state: W.states[:stalled],
  context: {}, kwargs: {}, options: {}, started_at: 28.minutes.ago, parent_execution_log_id: fo_branch.id)

# Large fan-out with a live, still-draining merge — the branches panel's
# throughput/ETA story (distinct from batch-7's dropped poller above). Every
# count comes from the poller's cached metadata, so no child rows are needed:
# spawned/pending/never-started, plus rate (children/s) and a derived ETA.
big = W.create!(key: "fanout-100k", job_class: "OrderProcessingWorkflow", state: W.states[:idle],
  context: {}, kwargs: {"count" => 100_000}, options: {}, started_at: 1.minute.ago)
big.update_columns(updated_at: big.started_at) # parked on the merge — duration 0s
E.create!(workflow: big, step_name: "branch$fanout", state: estate(:completed), attempts: 1,
  started_at: 1.minute.ago, completed_at: 1.minute.ago + 37,
  metadata: {"poll" => {"spawned" => 100_000, "pending" => 90_575, "never_started" => 90_567,
                        "rate" => 227.0, "eta_seconds" => 399, "sealed" => true, "polls" => 2,
                        "last_polled_at" => 1.minute.ago.iso8601, "next_poll_at" => 3.minutes.from_now.iso8601}})
E.create!(workflow: big, step_name: "merge$fanout", state: estate(:pending), attempts: 1, started_at: 1.minute.ago)

# Stranded in :running — a worker was hard-killed mid-pass, so the lock is stale
# (older than reap_stale_after, 30m by default) and nothing is scheduled to wake
# it. The reaper (and the Stranded page) catch it by the stale lock, NOT runtime:
# newsletter-9 above has run for days with a *fresh* lock and is perfectly healthy.
strand = W.create!(key: "batch-import-42", job_class: "OrderProcessingWorkflow", state: W.states[:running],
  context: {"batch" => 42}, kwargs: {"batch_id" => 42}, options: {},
  started_at: 90.minutes.ago, locked_at: 47.minutes.ago, locked_by: "worker-7f3a@host-2")
E.create!(workflow: strand, step_name: "durably_execute$fetch_rows", state: estate(:completed),
  attempts: 1, started_at: 90.minutes.ago, completed_at: 89.minutes.ago)
E.create!(workflow: strand, step_name: "durably_execute$process_batch", state: estate(:pending),
  attempts: 1, started_at: 48.minutes.ago, last_executed_at: 47.minutes.ago)

# Scheduled-payment recurrence — the definition-graph screenshot fixture. The run
# took the auto-charge "payment reminder first" branch, so those steps are done,
# the other two reminder branches stay not-reached (dimmed), and the final charge
# failed. Two guarded early-returns (not-running, past-dismiss) become halt exits.
sp = W.create!(key: "scheduled_payment_recurrence_5521_1782", job_class: "ScheduledPaymentRecurrenceWorkflow",
  state: W.states[:failed],
  context: {"scheduled_payment_id" => 5521, "payment_reminder_sent_at" => 26.hours.ago.iso8601,
            "auto_charge_reminder_sent_at" => 24.hours.ago.iso8601},
  kwargs: {"scheduled_payment_id" => 5521, "scheduled_time" => 2.days.ago.iso8601},
  options: {}, started_at: 3.days.ago)
E.create!(workflow: sp, step_name: "wait$wait_payment_reminder", state: estate(:completed),
  attempts: 1, started_at: 3.days.ago, completed_at: 26.hours.ago)
E.create!(workflow: sp, step_name: "durably_execute$send_payment_reminder", state: estate(:completed),
  attempts: 1, started_at: 26.hours.ago, completed_at: 26.hours.ago + 2)
E.create!(workflow: sp, step_name: "wait$wait_auto_charge_reminder", state: estate(:completed),
  attempts: 1, started_at: 26.hours.ago, completed_at: 24.hours.ago)
E.create!(workflow: sp, step_name: "durably_execute$send_auto_charge_reminder", state: estate(:completed),
  attempts: 1, started_at: 24.hours.ago, completed_at: 24.hours.ago + 2)
E.create!(workflow: sp, step_name: "wait$wait_for_payment_time", state: estate(:completed),
  attempts: 1, started_at: 24.hours.ago, completed_at: 3.hours.ago)
E.create!(workflow: sp, step_name: "durably_execute$process_payment", state: estate(:failed),
  attempts: 3, started_at: 3.hours.ago, error_class: "Payments::GatewayError")
L.create!(workflow: sp, step_name: "durably_execute$process_payment", attempt: 3,
  error_class: "Payments::GatewayError", error_message: "gateway declined: issuer unavailable",
  backtrace: "app/services/payments.rb:88\napp/jobs/scheduled_payment_recurrence_workflow.rb:52")

run Combustion::Application
