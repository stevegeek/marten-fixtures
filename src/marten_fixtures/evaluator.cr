require "yaml"
require "crinja"
require "./error"
require "./helper_registry"

module MartenFixtures
  # Template evaluator contract. Implementations turn the raw text of a
  # fixture YAML file into the final YAML string handed to the parser.
  module Evaluator
    abstract def evaluate(source : String, context : Hash(String, String)) : String
  end

  # No-op evaluator: returns the source unchanged. Used when a fixture
  # file has no template syntax. Detects accidental Crinja markers and
  # raises so users do not silently get an unevaluated template.
  class PlainEvaluator
    include Evaluator

    TEMPLATE_MARKERS = {"{{", "{%"}

    def evaluate(source : String, context : Hash(String, String)) : String
      if TEMPLATE_MARKERS.any? { |marker| source.includes?(marker) }
        raise Error::TemplateUnsupported.new(
          "Fixture source contains template syntax but PlainEvaluator is in use; " \
          "switch to CrinjaEvaluator or remove the {{ ... }} / {% ... %} markers."
        )
      end

      source
    end
  end

  # Crinja-backed evaluator. Each helper in the supplied `HelperRegistry`
  # is exposed as a global function on the Crinja environment so fixture
  # templates can call them as `{{ blob(filename="foo.webp") }}`.
  class CrinjaEvaluator
    include Evaluator

    # L6: setter so the Loader can re-inject a live EvalContext into a
    # `CrinjaEvaluator` that the user pre-constructed and stored on
    # `MartenFixtures.configuration.evaluator`. Without this, helper
    # invocations would raise the "EvalContext with a loaded label
    # registry" error from `build_function` because the pre-constructed
    # evaluator was built before any load had populated a registry.
    property eval_context : EvalContext?

    def initialize(
      @helper_registry : HelperRegistry = HelperRegistry.global,
      @eval_context : EvalContext? = nil,
    )
      @env = Crinja.new
      @registered_helper_names = Set(String).new
      sync_helpers
    end

    def evaluate(source : String, context : Hash(String, String)) : String
      # Re-sync before every render so a helper registered AFTER the
      # evaluator was constructed (e.g. by a Loader-time `require` or a
      # user `register_helper` call between two `evaluate`s) is still
      # visible to Crinja templates. Without this re-sync Crinja would
      # raise its own opaque `UndefinedError` for the new name.
      sync_helpers
      @env.from_string(source).render(context)
    end

    # Adds any registry helpers that are not yet exposed on the Crinja
    # environment. Once added, the per-name proc looks up the helper
    # lazily from the registry on every invocation, so subsequent
    # re-registrations under the same name are still visible.
    #
    # Removal is not handled: a helper unregistered after `sync_helpers`
    # ran will surface via the proc's "no longer registered" error path.
    #
    # M5: the `@registered_helper_names` dedup set is intentionally
    # per-CrinjaEvaluator-instance, NOT per-process. The two-instance
    # scenario the source review flagged ("could two CrinjaEvaluators
    # racing over the same HelperRegistry double-register?") is correctly
    # handled because each `CrinjaEvaluator` allocates its own
    # `@env = Crinja.new` at `initialize` (see line 43): the dedup set
    # guards writes into `@env.functions`, and the two evaluators have
    # disjoint `@env.functions` maps. So even if both call `sync_helpers`
    # concurrently for the same helper name, each writes into its own
    # `@env.functions` exactly once. No cross-evaluator race.
    #
    # (If a future refactor shares one `Crinja` env across evaluators,
    # this comment is wrong — at that point the dedup needs to move onto
    # the env or wrap a Mutex.)
    private def sync_helpers : Nil
      @helper_registry.each do |(name, _helper)|
        next if @registered_helper_names.includes?(name)
        @env.functions[name] = build_function(name)
        @registered_helper_names << name
      end
    end

    private def build_function(name : String) : Crinja::Callable::Instance
      registry = @helper_registry
      # L6: the proc captures `self` (not a snapshot of `@eval_context`)
      # and reads `evaluator.eval_context` on every invocation. That way,
      # if the Loader injects an EvalContext into a pre-constructed
      # `CrinjaEvaluator` between `initialize` and the first helper call,
      # the new context is visible to all built procs — including ones
      # that were sync'd in `initialize` before the context existed.
      evaluator = self
      proc = ->(arguments : Crinja::Arguments) do
        helper = registry.fetch(name) || raise Error::TemplateUnsupported.new(
          "Helper `#{name}` is no longer registered in the HelperRegistry."
        )

        args = {} of String => YAML::Any
        arguments.kwargs.each do |key, value|
          args[key] = to_yaml_any(value.raw)
        end

        ctx = evaluator.eval_context || raise Error::TemplateUnsupported.new(
          "Helper `#{name}` requires an EvalContext with a loaded label registry. " \
          "If you pre-construct CrinjaEvaluator in Configuration, the Loader cannot " \
          "inject a live registry — let the Loader build the evaluator instead, or " \
          "pass an EvalContext via the CrinjaEvaluator constructor."
        )

        Crinja::Value.new(helper.call(args, ctx))
      end

      Crinja::Callable::Instance.new(proc, Crinja::Variables.new, name)
    end

    # M4: the previous `else` branch silently called `.to_s` on any
    # unrecognised Crinja::Value#raw type. That's a latent bug — helpers
    # today return `Hash(String, String)`, so the path was unreachable in
    # practice, but the v0.2 plan in the README is to widen the helper
    # return type. Once a helper can return e.g. a `Time` (or `UInt32`,
    # `BigInt`, or a custom struct), the silent flatten makes a
    # column-shape mismatch invisible: the row ends up with `"2026-…"`
    # where the column expected a `Time::Span`, and the failure surfaces
    # only when the field's `to_db` rejects the string (often with a less
    # actionable error than the type-mismatch itself).
    #
    # Loud-fail: raise `Error::UnsupportedHelperReturnType` listing the
    # set we DO handle, so a v0.2 contributor extending helper signatures
    # gets a pointed error telling them exactly which branch to add.
    private def to_yaml_any(raw) : YAML::Any
      case raw
      when String, Int64, Float64, Bool, Nil
        YAML::Any.new(raw)
      when Int32, Int8, Int16
        YAML::Any.new(raw.to_i64)
      when Float32
        YAML::Any.new(raw.to_f64)
      when Crinja::SafeString
        YAML::Any.new(raw.to_s)
      when Crinja::Undefined
        raise Error::TemplateUnsupported.new(
          "Helper argument resolved to Crinja::Undefined — check the template " \
          "variable name; the referenced symbol is not defined in the template context."
        )
      when Array
        YAML::Any.new(raw.map { |item| to_yaml_any(item.is_a?(Crinja::Value) ? item.raw : item) })
      when Hash
        mapped = {} of YAML::Any => YAML::Any
        raw.each do |k, v|
          mapped[YAML::Any.new(k.to_s)] =
            to_yaml_any(v.is_a?(Crinja::Value) ? v.raw : v)
        end
        YAML::Any.new(mapped)
      else
        raise Error::UnsupportedHelperReturnType.new(
          "Crinja helper returned a value of unsupported Crystal type " \
          "#{raw.class}: #{raw.inspect}. The Crinja → YAML bridge in " \
          "MartenFixtures::CrinjaEvaluator only recognises: " \
          "String, Int8/16/32/64, Float32/64, Bool, Nil, Crinja::SafeString, " \
          "Array, and Hash. If you need to return another type, convert it " \
          "to one of these (e.g. `time.to_rfc3339` for a Time, `int.to_s` for " \
          "a UInt32) inside the helper itself."
        )
      end
    end
  end
end
