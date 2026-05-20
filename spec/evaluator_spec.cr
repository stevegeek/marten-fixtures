require "./spec_helper"

describe MartenFixtures::PlainEvaluator do
  it "passes the source through unchanged when no template markers are present" do
    source = "david:\n  name: David\n"
    MartenFixtures::PlainEvaluator.new.evaluate(source, {} of String => String).should eq(source)
  end

  it "raises Error::TemplateUnsupported when {{ ... }} appears in the source" do
    expect_raises(MartenFixtures::Error::TemplateUnsupported, /template syntax/i) do
      MartenFixtures::PlainEvaluator.new.evaluate("x: {{ y }}\n", {} of String => String)
    end
  end

  it "raises Error::TemplateUnsupported when {% ... %} block syntax appears" do
    expect_raises(MartenFixtures::Error::TemplateUnsupported, /template syntax/i) do
      MartenFixtures::PlainEvaluator.new.evaluate(
        "x: {% if y %}1{% endif %}\n",
        {} of String => String,
      )
    end
  end
end

describe MartenFixtures::CrinjaEvaluator do
  it "renders Crinja template markers against the supplied context" do
    eval_context = MartenFixtures::EvalContext.new(
      Path["spec/fixtures"],
      MartenFixtures::LabelRegistry.new,
    )
    evaluator = MartenFixtures::CrinjaEvaluator.new(
      helper_registry: MartenFixtures::HelperRegistry.new,
      eval_context: eval_context,
    )
    rendered = evaluator.evaluate(
      "greeting: hello {{ name }}\n",
      {"name" => "world"},
    )
    rendered.should contain("hello world")
  end

  it "invokes a registered helper inside a template and substitutes its return value" do
    registry = MartenFixtures::HelperRegistry.new
    registry.register("shout") do |args, _ctx|
      word = args["word"].as_s
      {"value" => word.upcase}
    end
    eval_context = MartenFixtures::EvalContext.new(
      Path["spec/fixtures"],
      MartenFixtures::LabelRegistry.new,
    )
    evaluator = MartenFixtures::CrinjaEvaluator.new(
      helper_registry: registry,
      eval_context: eval_context,
    )

    rendered = evaluator.evaluate(
      "greeting: {{ shout(word=\"hello\").value }}\n",
      {} of String => String,
    )
    rendered.should contain("HELLO")
  end

  it "raises Error::TemplateUnsupported with the improved guidance message when a helper is invoked without an EvalContext" do
    registry = MartenFixtures::HelperRegistry.new
    registry.register("noop") do |_args, _ctx|
      {} of String => String
    end
    evaluator = MartenFixtures::CrinjaEvaluator.new(helper_registry: registry, eval_context: nil)

    expect_raises(MartenFixtures::Error::TemplateUnsupported, /let the Loader build the evaluator/) do
      evaluator.evaluate("x: {{ noop() }}\n", {} of String => String)
    end
  end
end
