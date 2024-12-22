class KitchenSink < WorkflowJob
  prepend ChronoForge::Executor

  def perform(kwarg: nil, succeed: true)
    # Context can be used to pass and store data between executions
    context[:order_id] ||= SecureRandom.hex

    # Wait until payment is confirmed
    wait_until :payment_confirmed?,
      timeout: 1.second,
      check_interval: 0.1.second

    # Wait for potential fraud check
    wait 1.seconds, :fraud_check_delay

    # Durably execute order processing
    durably_execute :process_order

    raise "Permanent Failure" unless succeed

    # Final steps
    durably_execute :complete_order
  end

  private

  def payment_confirmed?
    result_list = context[:payment_confirmation_results] ||= [true, false, false]
    result = result_list.pop
    context[:payment_confirmation_results] = result_list
    result
  end

  def process_order
    context["processed_at"] = Time.current.iso8601
  end

  def complete_order
    context["completed_at"] = Time.current.iso8601
  end
end
