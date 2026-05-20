class Leaf < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :position, :int, blank: false, null: false
  field :leafable, :polymorphic, to: [Post, Tag]

  with_timestamp_fields

  db_table "leaves"
end
