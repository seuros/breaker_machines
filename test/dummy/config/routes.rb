# frozen_string_literal: true

Rails.application.routes.draw do
  # Health check
  get 'health', to: 'health#show'

  # Weather API endpoints
  get 'weather', to: 'weather#show'
  get 'force_failure', to: 'weather#force_failure'

  # Circuit management endpoints
  get 'circuits', to: 'circuits#index'
  post 'circuits/:name/reset', to: 'circuits#reset'

  # Test endpoints for circuit breaker functionality
  get 'test/payment', to: 'test#payment'
  get 'test/notification', to: 'test#notification'
  get 'test/status', to: 'test#status'
  post 'test/trip_payment', to: 'test#trip_payment'
  post 'test/reset', to: 'test#reset'
end
