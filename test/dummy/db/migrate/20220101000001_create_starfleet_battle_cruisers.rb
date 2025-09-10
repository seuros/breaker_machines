# frozen_string_literal: true

class CreateStarfleetBattleCruisers < ActiveRecord::Migration[7.2]
  def change
    create_table :starfleet_battle_cruisers do |t|
      t.string :name
      t.string :registry
      t.string :captain
      t.string :battle_status
      t.boolean :warp_engaged, default: false
      t.boolean :shields_up, default: false
      t.datetime :red_alert_engaged_at
      t.datetime :critical_status_at

      t.timestamps
    end
  end
end
