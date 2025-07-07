# frozen_string_literal: true

class TestController < ApplicationController
  before_action :initialize_service

  # Process a payment through circuit breaker
  def payment
    amount = params[:amount]&.to_f || 100.0
    card_token = params[:card_token] || 'test-token'
    result = @service.process_payment(amount, card_token)

    render json: result
  end

  # Send notification through circuit breaker
  def notification
    email = params[:email] || 'test@example.com'
    subject = params[:subject] || 'Test Notification'
    body = params[:body] || 'This is a test notification'

    result = @service.send_notification(email, subject, body)

    render json: result
  end

  # Get circuit breaker status
  def status
    render json: @service.service_status
  end

  # Force circuit to trip for testing
  def trip_payment
    results = []

    # Force multiple failures to trip the circuit
    5.times do
      @service.circuit(:payment_gateway).wrap do
        raise StandardError, 'Forced failure for testing'
      end
    rescue StandardError => e
      results << { error: e.message, class: e.class.name }
    end

    render json: {
      message: 'Attempted to trip payment circuit',
      results: results,
      circuit_state: @service.circuit(:payment_gateway).status_name
    }
  end

  # Reset circuits
  def reset
    # Only reset if not already closed
    payment_circuit = @service.circuit(:payment_gateway)
    email_circuit = @service.circuit(:email_service)

    payment_circuit.reset! if payment_circuit.open? || payment_circuit.half_open?
    email_circuit.reset! if email_circuit.open? || email_circuit.half_open?

    render json: {
      message: 'Circuits reset',
      status: @service.service_status
    }
  end

  private

  def initialize_service
    @service = ExternalApiService.new
  end
end
