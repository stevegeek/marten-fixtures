require "./spec_helper"

describe MartenFixtures::HelperRegistry do
  it "stores a helper Proc under the registered name and exposes it via #fetch" do
    registry = MartenFixtures::HelperRegistry.new
    registry.register("noop") do |_args, _ctx|
      {"key" => "value"} of String => String
    end

    registry.size.should eq(1)
    helper = registry.fetch("noop")
    helper.should_not be_nil
    eval_context = MartenFixtures::EvalContext.new(Path["spec/fixtures"], MartenFixtures::LabelRegistry.new)
    helper.not_nil!.call({} of String => YAML::Any, eval_context).should eq({"key" => "value"})
  end

  it "returns nil from #fetch for an unknown name" do
    registry = MartenFixtures::HelperRegistry.new
    registry.fetch("nope").should be_nil
  end

  it "resets the process-wide singleton when reset_global! is called" do
    MartenFixtures.register_helper("temp_helper") do |_args, _ctx|
      {} of String => String
    end
    MartenFixtures::HelperRegistry.global.fetch("temp_helper").should_not be_nil

    MartenFixtures::HelperRegistry.reset_global!
    MartenFixtures::HelperRegistry.global.fetch("temp_helper").should be_nil
  end

  it "registers a helper on the global registry via MartenFixtures.register_helper and surfaces it from a template" do
    MartenFixtures.register_helper("digest") do |args, _ctx|
      word = args["word"].as_s
      {"value" => "digest:#{word}"}
    end

    eval_context = MartenFixtures::EvalContext.new(
      Path["spec/fixtures"],
      MartenFixtures::LabelRegistry.new,
    )
    evaluator = MartenFixtures::CrinjaEvaluator.new(
      helper_registry: MartenFixtures::HelperRegistry.global,
      eval_context: eval_context,
    )
    rendered = evaluator.evaluate(
      "value: {{ digest(word=\"david\").value }}\n",
      {} of String => String,
    )
    rendered.should contain("digest:david")
  end

  it "carries fixtures_path + label_registry on the EvalContext handed to helpers" do
    label_registry = MartenFixtures::LabelRegistry.new
    label_registry.register(Account, "engineering", 42_i64)
    captured = uninitialized MartenFixtures::EvalContext

    registry = MartenFixtures::HelperRegistry.new
    registry.register("capture") do |_args, ctx|
      captured = ctx
      {} of String => String
    end

    helper = registry.fetch("capture").not_nil!
    ctx = MartenFixtures::EvalContext.new(Path["spec/fixtures"], label_registry)
    helper.call({} of String => YAML::Any, ctx)

    captured.fixtures_path.should eq(Path["spec/fixtures"])
    captured.label_registry.lookup(Account, "engineering").should eq(42_i64)
  end
end
