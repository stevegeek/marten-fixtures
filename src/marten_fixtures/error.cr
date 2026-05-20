module MartenFixtures
  class Error < Exception
    class UnknownTable < Error; end

    class UnknownLabel < Error; end

    class UnknownPolymorphicType < Error; end

    class UnknownField < Error; end

    class UnsupportedPK < Error; end

    class TemplateUnsupported < Error; end
  end
end
