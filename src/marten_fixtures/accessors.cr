module MartenFixtures
  # Spec-side sugar. `include MartenFixtures::Accessors` in a `describe`
  # block (or a shared spec helper) to gain a single `fixture/2` method
  # that looks up a previously loaded row by label and returns the model
  # instance.
  module Accessors
    def fixture(model_class : Marten::DB::Model.class, label : String | Symbol) : Marten::DB::Model
      pk_field = model_class.fields.find!(&.primary_key?)
      pk = MartenFixtures::Label.identify(label.to_s, pk_field)
      model_class.get!(pk: pk)
    end
  end
end
