class Sample < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :name, :string, max_size: 255, blank: false, null: false
  field :metadata, :json, null: true
  field :ttl, :duration, null: true
  field :scheduled_on, :date, null: true

  with_timestamp_fields

  db_table "samples"
end
