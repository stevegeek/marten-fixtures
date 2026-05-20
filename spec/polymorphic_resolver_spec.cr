require "./spec_helper"

private def leaf_polymorphic_field : Marten::DB::Field::Polymorphic
  Leaf.get_field("leafable").as(Marten::DB::Field::Polymorphic)
end

describe MartenFixtures::PolymorphicResolver do
  describe ".parse_value" do
    it "returns nil when the value carries no (Type) suffix" do
      MartenFixtures::PolymorphicResolver.parse_value("welcome").should be_nil
    end

    it "parses 'welcome (Post)' into a label/type tuple" do
      MartenFixtures::PolymorphicResolver.parse_value("welcome (Post)").should eq({"welcome", "Post"})
    end
  end

  describe ".resolve" do
    it "returns a {FQCN, model_class} tuple for a recognised short type" do
      fqcn, model_class = MartenFixtures::PolymorphicResolver.resolve(leaf_polymorphic_field, "Post")
      fqcn.should eq("Post")
      model_class.should eq(Post)
    end

    it "raises Error::UnknownPolymorphicType including the allowed-target list when the short type is not in @to" do
      expect_raises(
        MartenFixtures::Error::UnknownPolymorphicType,
        /Unknown polymorphic target "Bogus".*allowed: Post, Tag/,
      ) do
        MartenFixtures::PolymorphicResolver.resolve(leaf_polymorphic_field, "Bogus")
      end
    end
  end

  describe ".target_models" do
    it "exposes the closed @to list without callers reaching into the ivar" do
      MartenFixtures::PolymorphicResolver.target_models(leaf_polymorphic_field).should eq([Post, Tag])
    end
  end
end
