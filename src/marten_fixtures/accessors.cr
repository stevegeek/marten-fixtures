module MartenFixtures
  # Spec-side sugar. `include MartenFixtures::Accessors` in a `describe`
  # block (or a shared spec helper) to gain a single `fixture/2` method
  # that looks up a previously loaded row by label and returns the model
  # instance.
  module Accessors
    # Resolves a row by label. Consults the most recently loaded
    # `LabelRegistry` first so that rows with explicit `id:` values are
    # found (H1 / L12); falls back to the deterministic CRC32 / UUID-v5
    # derivation when no registry is available (e.g. when the caller
    # hasn't yet invoked `MartenFixtures.load*`).
    def fixture(model_class : Marten::DB::Model.class, label : String | Symbol) : Marten::DB::Model
      label_str = label.to_s
      registry = MartenFixtures.last_label_registry
      pk = registry.try(&.lookup?(model_class, label_str))
      if pk.nil?
        pk_field = model_class.fields.find!(&.primary_key?)
        pk = MartenFixtures::Label.identify(label_str, pk_field)
      end
      model_class.get!(pk: pk)
    end
  end
end
