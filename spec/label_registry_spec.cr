require "./spec_helper"

describe MartenFixtures::LabelRegistry do
  describe "#lookup" do
    it "raises Error::UnknownLabel with the model name and label embedded in the message" do
      registry = MartenFixtures::LabelRegistry.new
      expect_raises(MartenFixtures::Error::UnknownLabel, /User\/nobody/) do
        registry.lookup(User, "nobody")
      end
    end
  end

  describe "#lookup?" do
    it "returns nil when no entry exists for the given model/label" do
      registry = MartenFixtures::LabelRegistry.new
      registry.lookup?(User, "ghost").should be_nil
    end
  end

  describe "#register" do
    it "overwrites the existing entry when called twice with the same model/label" do
      registry = MartenFixtures::LabelRegistry.new
      registry.register(User, "david", 1_i64)
      registry.register(User, "david", 99_i64)
      registry.lookup(User, "david").should eq(99_i64)
      registry.size.should eq(1)
    end
  end
end
