# frozen_string_literal: true

# Fighter inherits base circuits and adds weapons
class Fighter < BaseSpaceship
  circuit :weapons do
    threshold failures: 2, within: 30
    reset_after 20
    fallback { 'Manual targeting' }
  end

  def fire_lasers
    circuit(:weapons).wrap { 'Lasers fired' }
  end
end
