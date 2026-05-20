require "./spec_helper"

private def yaml_attrs(yaml : String) : Hash(String, YAML::Any)
  raw = YAML.parse(yaml).as_h
  attrs = {} of String => YAML::Any
  raw.each { |k, v| attrs[k.as_s] = v }
  attrs
end

describe MartenFixtures::RowInterpolator do
  it "expands a ManyToOne label reference into the *_id column" do
    registry = MartenFixtures::LabelRegistry.new
    account_pk = MartenFixtures::Label.identify("engineering")
    registry.register(Account, "engineering", account_pk)

    interpolator = MartenFixtures::RowInterpolator.new(User, registry, :auto)
    attrs = yaml_attrs(<<-YAML)
      name: David
      email: david@example.com
      account: engineering
      password_digest: "$2a$12$x"
    YAML

    row = interpolator.interpolate("david", attrs)
    row["account_id"].should eq(account_pk)
    row.has_key?("account").should be_false
  end

  it "expands polymorphic shorthand into *_type / *_id columns" do
    registry = MartenFixtures::LabelRegistry.new
    user_pk = MartenFixtures::Label.identify("david")
    post_pk = MartenFixtures::Label.identify("welcome")
    registry.register(User, "david", user_pk)
    registry.register(Post, "welcome", post_pk)

    interpolator = MartenFixtures::RowInterpolator.new(Leaf, registry, :auto)
    attrs = yaml_attrs(<<-YAML)
      position: 1
      leafable: welcome (Post)
    YAML

    row = interpolator.interpolate("lead_welcome", attrs)
    row["leafable_type"].should eq("Post")
    row["leafable_id"].should eq(post_pk)
  end

  it "auto-fills created_at / updated_at when timestamp_policy is :auto" do
    registry = MartenFixtures::LabelRegistry.new
    interpolator = MartenFixtures::RowInterpolator.new(Account, registry, :auto)
    attrs = yaml_attrs(<<-YAML)
      name: Engineering
    YAML

    row = interpolator.interpolate("engineering", attrs)
    row["created_at"].should_not be_nil
    row["updated_at"].should_not be_nil
  end

  it "raises Error::UnknownField when a row references an unknown column" do
    registry = MartenFixtures::LabelRegistry.new
    interpolator = MartenFixtures::RowInterpolator.new(Account, registry, :auto)
    attrs = yaml_attrs(<<-YAML)
      name: Engineering
      bogus_column: nope
    YAML

    expect_raises(MartenFixtures::Error::UnknownField, /bogus_column/) do
      interpolator.interpolate("engineering", attrs)
    end
  end

  it "raises Error when timestamp_policy is :required and the timestamp column is missing" do
    registry = MartenFixtures::LabelRegistry.new
    interpolator = MartenFixtures::RowInterpolator.new(Account, registry, :required)
    attrs = yaml_attrs(<<-YAML)
      name: Engineering
    YAML

    expect_raises(MartenFixtures::Error, /missing required timestamp column/) do
      interpolator.interpolate("engineering", attrs)
    end
  end

  it "omits created_at / updated_at from the emitted row when timestamp_policy is :skip" do
    registry = MartenFixtures::LabelRegistry.new
    interpolator = MartenFixtures::RowInterpolator.new(Account, registry, :skip)
    attrs = yaml_attrs(<<-YAML)
      name: Engineering
    YAML

    row = interpolator.interpolate("engineering", attrs)
    row.has_key?("created_at").should be_false
    row.has_key?("updated_at").should be_false
  end

  it "raises Error::UnknownPolymorphicType when a polymorphic value omits the (Type) parens" do
    registry = MartenFixtures::LabelRegistry.new
    interpolator = MartenFixtures::RowInterpolator.new(Leaf, registry, :auto)
    attrs = yaml_attrs(<<-YAML)
      position: 1
      leafable: welcome
    YAML

    expect_raises(MartenFixtures::Error::UnknownPolymorphicType, /must be in the form/) do
      interpolator.interpolate("lead_welcome", attrs)
    end
  end

  it "propagates Error::UnknownLabel when a FK label was never registered" do
    registry = MartenFixtures::LabelRegistry.new
    interpolator = MartenFixtures::RowInterpolator.new(User, registry, :auto)
    attrs = yaml_attrs(<<-YAML)
      name: David
      email: david@example.com
      account: ghost_account
      password_digest: x
    YAML

    expect_raises(MartenFixtures::Error::UnknownLabel, /Account\/ghost_account/) do
      interpolator.interpolate("david", attrs)
    end
  end
end
