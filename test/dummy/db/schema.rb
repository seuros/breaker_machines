# frozen_string_literal: true

# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 20_220_101_000_001) do
  create_table 'starfleet_battle_cruisers', force: :cascade do |t|
    t.string 'name'
    t.string 'registry'
    t.string 'captain'
    t.string 'battle_status'
    t.boolean 'warp_engaged', default: false
    t.boolean 'shields_up', default: false
    t.datetime 'red_alert_engaged_at'
    t.datetime 'critical_status_at'
    t.datetime 'created_at', null: false
    t.datetime 'updated_at', null: false
  end
end
