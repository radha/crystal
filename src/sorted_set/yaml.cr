require "yaml"
require "sorted_set"

class SortedSet(T)
  # Reads a set from a YAML sequence; duplicates are kept once.
  #
  # NOTE: `require "sorted_set/yaml"` is required to opt-in to this feature.
  def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
    ctx.read_alias(node, self) do |obj|
      return obj
    end

    unless node.is_a?(YAML::Nodes::Sequence)
      node.raise "Expected sequence, not #{node.kind}"
    end

    set = new
    ctx.record_anchor(node, set)
    node.each do |value|
      set << T.new(ctx, value)
    end
    set
  end

  # Writes the set as a YAML sequence, in order.
  #
  # NOTE: `require "sorted_set/yaml"` is required to opt-in to this feature.
  def to_yaml(yaml : YAML::Nodes::Builder) : Nil
    yaml.sequence(reference: self) do
      each &.to_yaml(yaml)
    end
  end
end
