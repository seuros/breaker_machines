# frozen_string_literal: true

class ExternalApiService
  include BreakerMachines::DSL

  # Test control for deterministic behavior
  cattr_accessor :test_payment_behavior

  def circuit(name)
    case name
    when :payment_gateway
      dynamic_circuit(:payment_gateway, global: true) do
        threshold failures: 3, within: 1.minute
        reset_after 30.seconds
        timeout 10.seconds

        fallback do |_error|
          {
            status: 'queued',
            message: 'Payment will be processed when service recovers',
            reference: SecureRandom.uuid
          }
        end

        on_open do
          Rails.logger.error 'Payment gateway circuit opened!'
        end

        on_close do
          Rails.logger.info 'Payment gateway circuit closed - service recovered'
        end
      end
    when :email_service
      dynamic_circuit(:email_service, global: true) do
        threshold failure_rate: 0.5, minimum_calls: 10, within: 2.minutes
        reset_after 1.minute

        fallback do |error|
          # Don't retry emails, just log
          Rails.logger.warn "Email not sent due to circuit open: #{error.message}"
          { sent: false, queued: true }
        end
      end
    else
      super
    end
  end

  def process_payment(amount, _card_token)
    circuit(:payment_gateway).wrap do
      # Simulate payment processing with 10% failure rate
      raise 'Payment gateway timeout' if should_fail_payment?

      {
        status: 'success',
        transaction_id: SecureRandom.uuid,
        amount: amount,
        timestamp: Time.current
      }
    end
  end

  def send_notification(_email, _subject, _body)
    circuit(:email_service).wrap do
      # Simulate email sending
      raise 'SMTP connection failed' if rand > 0.95 # 5% failure rate

      {
        sent: true,
        message_id: SecureRandom.uuid,
        timestamp: Time.current
      }
    end
  end

  # Example of checking circuit state before expensive operations
  def can_process_payments?
    !circuit(:payment_gateway).open?
  end

  def service_status
    payment_stats = circuit(:payment_gateway).stats
    email_stats = circuit(:email_service).stats

    {
      payment_gateway: {
        available: !circuit(:payment_gateway).open?,
        state: payment_stats.state,
        failure_count: payment_stats.failure_count
      },
      email_service: {
        available: !circuit(:email_service).open?,
        state: email_stats.state,
        failure_count: email_stats.failure_count
      }
    }
  end

  private

  def should_fail_payment?
    # Allow tests to override this behavior
    return test_payment_behavior == :fail if test_payment_behavior

    rand > 0.9
  end
end
