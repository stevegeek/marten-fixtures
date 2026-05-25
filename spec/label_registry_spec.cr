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
    it "is idempotent when called twice with the same model/label/pk (L1)" do
      # Same-pk re-registration is a no-op — this happens harmlessly when
      # callers replay a partial load, and shouldn't trip the duplicate
      # guard. Pre-L1 the second call also "succeeded" (silent overwrite);
      # the contract change is that DIFFERENT pks now raise.
      registry = MartenFixtures::LabelRegistry.new
      registry.register(User, "david", 99_i64)
      registry.register(User, "david", 99_i64)
      registry.lookup(User, "david").should eq(99_i64)
      registry.size.should eq(1)
    end

    it "raises Error::DuplicateLabel when re-registering the same key with a different pk (L1)" do
      # Pre-L1 this silently overwrote, corrupting cross-fixture FK
      # resolution: a label registered to pk=1 by file A then to pk=99 by
      # file B would have FK references from a third file resolving to
      # 99 while file A's row carries id=1 (or vice-versa, depending on
      # iteration order). Raising at register time surfaces the bug at
      # load time instead of as an opaque orphan-row / FK-violation.
      registry = MartenFixtures::LabelRegistry.new
      registry.register(User, "david", 1_i64)
      expect_raises(
        MartenFixtures::Error::DuplicateLabel,
        /User\/david.+pk=1.+pk=99/,
      ) do
        registry.register(User, "david", 99_i64)
      end
      # On raise, the original entry stays put (no partial corruption).
      registry.lookup(User, "david").should eq(1_i64)
      registry.size.should eq(1)
    end

    it "does not conflate UUID-string and Int64 pks (L1)" do
      # The Crystal `==` between Int64 and String is false, so the guard
      # treats a String pk and an Int64 pk as different — which is the
      # correct semantic for fixtures: a Label::identify return type
      # depends on the model's pk field type, and the same label across
      # two models with different pk types would never both be stored
      # under the same key (the key includes the model class name), but
      # locking the behaviour prevents a future bug.
      registry = MartenFixtures::LabelRegistry.new
      registry.register(User, "david", 1_i64)
      expect_raises(MartenFixtures::Error::DuplicateLabel) do
        registry.register(User, "david", "1")
      end
    end
  end
end
