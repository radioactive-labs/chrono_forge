# A trimmed copy of a real production workflow (achieve by Petra), used to render
# the definition-graph screenshot. Never executed here — the seed fabricates logs
# for one taken branch, so the graph shows that path live and the others dimmed.
#
# Unlike the original, the mutually-exclusive reminder branches use DISTINCT step
# names. Reusing one name across branches makes them the same durable step, so a
# run through either branch would light up every drawn copy (and, at runtime, the
# first branch reached would complete the step and the others would skip it).
class ScheduledPaymentRecurrenceWorkflow < ActiveJob::Base
  prepend ChronoForge::Executor

  def perform(scheduled_payment_id:, scheduled_time:)
    @scheduled_payment = ScheduledPayment.find(scheduled_payment_id)
    @scheduled_for = Time.parse(scheduled_time)

    context.set_once("scheduled_payment_id", scheduled_payment_id)

    return unless @scheduled_payment.running?

    lead_time = [@scheduled_payment.remind_at_delta, auto_charge? ? 24.hours : 0].max
    payment_process_time = @scheduled_for + lead_time
    payment_reminder_time = payment_process_time - @scheduled_payment.remind_at_delta
    dismiss_at = payment_process_time + @scheduled_payment.dismiss_at_delta

    if Time.current > dismiss_at
      context["workflow_skipped"] = true
      return
    end

    if auto_charge?
      auto_charge_reminder_time = payment_process_time - 24.hours

      if payment_reminder_time < auto_charge_reminder_time
        wait (payment_reminder_time - Time.current).seconds, "wait_payment_reminder"
        durably_execute :send_payment_reminder
        wait (auto_charge_reminder_time - Time.current).seconds, "wait_auto_charge_reminder"
        durably_execute :send_auto_charge_reminder
      else
        wait (auto_charge_reminder_time - Time.current).seconds, "wait_auto_charge_reminder_first"
        durably_execute :send_auto_charge_reminder, name: "send_auto_charge_reminder_first"
        wait (payment_reminder_time - Time.current).seconds, "wait_payment_reminder_second"
        durably_execute :send_payment_reminder, name: "send_payment_reminder_second"
      end
    else
      wait (payment_reminder_time - Time.current).seconds, "wait_payment_reminder_only"
      durably_execute :send_payment_reminder, name: "send_payment_reminder_only"
    end

    wait (payment_process_time - Time.current).seconds, "wait_for_payment_time"
    durably_execute :process_payment
  end

  private

  def auto_charge? = @scheduled_payment.auto_charge? && @scheduled_payment.supports_auto_charge?

  def send_payment_reminder = @scheduled_payment.remind_payment(invoked_by: @workflow.key)

  def send_auto_charge_reminder = @scheduled_payment.remind_auto_charge(invoked_by: @workflow.key)

  def process_payment = @scheduled_payment.charge!(reference: @workflow.key)
end
