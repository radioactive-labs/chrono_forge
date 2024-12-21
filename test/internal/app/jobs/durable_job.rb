class DurableJob < ActiveJob::Base
  prepend ChronoForge::Executor

  def perform
    # Context can be used to pass and store data between executions
    context["order_id"] = SecureRandom.hex

    # Wait until payment is confirmed
    wait_until :payment_confirmed?

    # Wait for potential fraud check
    wait 1.seconds, :fraud_check_delay

    # Durably execute order processing
    durably_execute :process_order

    # Final steps
    complete_order
  end

  private

  def payment_confirmed?
    [true, false].sample
  end

  def process_order
    context["processed_at"] = Time.current.iso8601
  end

  def complete_order
    context["completed_at"] = Time.current.iso8601
  end
end
