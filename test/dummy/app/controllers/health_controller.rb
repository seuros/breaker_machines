# frozen_string_literal: true

class HealthController < ApplicationController
  def show
    health_status = {
      status: 'ok',
      timestamp: Time.current,
      services: check_services
    }

    render json: health_status
  end

  private

  def check_services
    {
      circuits: check_circuits
    }
  end

  def check_circuits
    open_circuits = BreakerMachines.registry.all_circuits.select(&:open?).map(&:name)

    if open_circuits.empty?
      'all circuits closed'
    else
      "open circuits: #{open_circuits.join(', ')}"
    end
  end
end
