# Example: Webhook-driven Payment Processing Workflow
#
# This example demonstrates how to use continue_if for workflows that need to wait
# for external events like webhook notifications without consuming resources on polling.

class PaymentProcessingWorkflow < ApplicationJob
  prepend ChronoForge::Executor

  def perform(order_id:)
    @order_id = order_id

    # Store order details in durable context
    context[:order_id] = @order_id
    context[:created_at] = Time.current.iso8601

    # Step 1: Initialize payment request
    durably_execute :initialize_payment

    # Step 2: Wait for payment confirmation (webhook-driven)
    # This will halt the workflow until manually retried when webhook arrives
    continue_if :payment_confirmed?, name: "stripe_payment_webhook"

    # Step 3: Process successful payment
    durably_execute :process_payment_success

    # Step 4: Send confirmation to customer
    durably_execute :send_confirmation
  end

  private

  def initialize_payment
    # Create payment request with external payment provider
    payment_request = PaymentService.create_payment_request(
      order_id: @order_id,
      amount: Order.find(@order_id).total_amount
    )

    context[:payment_request_id] = payment_request.id
    context[:payment_status] = "pending"

    Rails.logger.info "Payment request created for order #{@order_id}: #{payment_request.id}"
  end

  def payment_confirmed?
    # Check if payment has been confirmed by webhook
    payment_id = context[:payment_request_id]
    payment = PaymentService.find_payment(payment_id)

    confirmed = payment&.status == "confirmed"

    if confirmed
      context[:payment_status] = "confirmed"
      context[:confirmed_at] = Time.current.iso8601
    end

    Rails.logger.debug "Payment confirmation check for #{payment_id}: #{confirmed}"
    confirmed
  end

  def process_payment_success
    # Update order status and inventory
    order = Order.find(@order_id)
    order.mark_as_paid!

    # Update inventory
    InventoryService.reserve_items(order.items)

    context[:processed_at] = Time.current.iso8601
    Rails.logger.info "Payment processed successfully for order #{@order_id}"
  end

  def send_confirmation
    # Send confirmation email to customer
    order = Order.find(@order_id)
    OrderMailer.payment_confirmation(order).deliver_now

    context[:confirmation_sent_at] = Time.current.iso8601
    Rails.logger.info "Confirmation email sent for order #{@order_id}"
  end
end

# Webhook handler that resumes the workflow
class PaymentWebhookController < ApplicationController
  def receive
    payment_id = params[:payment_id]
    status = params[:status]

    if status == "confirmed"
      # Update payment status in your system
      PaymentService.update_payment_status(payment_id, "confirmed")

      # Find and continue the corresponding workflow
      order_id = PaymentService.find_payment(payment_id).order_id
      workflow_key = "payment-#{order_id}"

      # Continue the workflow from where it left off (continue_if)
      PaymentProcessingWorkflow.perform_later(workflow_key, order_id: order_id)

      Rails.logger.info "Payment confirmed via webhook, continuing workflow #{workflow_key}"
    end

    head :ok
  end
end

# Usage example:
#
# 1. Start the workflow:
#    PaymentProcessingWorkflow.perform_later("payment-order-123", order_id: "order-123")
#
# 2. Workflow will:
#    - Create payment request
#    - Check if payment is confirmed (initially false)
#    - Halt execution and wait in idle state
#
# 3. When webhook arrives:
#    - PaymentWebhookController#receive processes webhook
#    - Updates payment status to "confirmed"
#    - Calls PaymentProcessingWorkflow.perform_later("payment-order-123", order_id: "order-123")
#
# 4. Workflow resumes:
#    - Re-evaluates payment_confirmed? (now returns true)
#    - Continues with processing payment success
#    - Sends confirmation email
#    - Completes workflow

# Key benefits of continue_if vs wait_until:
#
# 1. No resource consumption: No background polling jobs
# 2. Instant response: Resumes immediately when condition changes
# 3. Webhook-friendly: Perfect for external event-driven workflows
# 4. Durable: Survives system restarts and deployments
# 5. Traceable: All state changes are logged in execution logs
