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

# Idle, waiting a long time (flagged in wait-states view)
wf2 = W.create!(key: "signup-77", job_class: "OrderWorkflow", state: W.states[:idle],
  context: {"user_id" => 77}, kwargs: {}, options: {}, started_at: 5.hours.ago)
E.create!(workflow: wf2, step_name: "wait_until$kyc_approved?", state: estate(:pending), attempts: 1,
  started_at: 5.hours.ago, last_executed_at: 5.hours.ago, metadata: {"timeout_at" => 2.hours.from_now.iso8601})

# Completed
wf3 = W.create!(key: "order-1000", job_class: "OrderWorkflow", state: W.states[:completed],
  context: {"amount" => 1200}, kwargs: {}, options: {}, started_at: 1.day.ago, completed_at: 1.day.ago)
E.create!(workflow: wf3, step_name: "durably_execute$process", state: estate(:completed), attempts: 1, started_at: 1.day.ago, completed_at: 1.day.ago)

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

# Stalled
W.create!(key: "payout-3", job_class: "OrderWorkflow", state: W.states[:stalled],
  context: {}, kwargs: {}, options: {}, started_at: 1.hour.ago)

run Combustion::Application
