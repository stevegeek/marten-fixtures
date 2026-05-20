require "./spec_helper"

describe MartenFixtures::Configuration do
  describe "#timestamp_policy=" do
    it "raises ArgumentError when given a symbol outside VALID_TIMESTAMP_POLICIES" do
      config = MartenFixtures::Configuration.new
      expect_raises(ArgumentError, /Invalid timestamp_policy/) do
        config.timestamp_policy = :bogus
      end
    end

    it "accepts each member of VALID_TIMESTAMP_POLICIES" do
      config = MartenFixtures::Configuration.new
      MartenFixtures::Configuration::VALID_TIMESTAMP_POLICIES.each do |policy|
        config.timestamp_policy = policy
        config.timestamp_policy.should eq(policy)
      end
    end
  end

  describe "#fixtures_path=" do
    it "coerces a String into a Path" do
      config = MartenFixtures::Configuration.new
      config.fixtures_path = "tmp/elsewhere"
      config.fixtures_path.should eq(Path["tmp/elsewhere"])
      config.fixtures_path.should be_a(Path)
    end
  end
end
