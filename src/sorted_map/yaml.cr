require "yaml"
require "sorted_map"

class SortedMap(K, V)
  # Reads a map from a YAML mapping. When a key repeats, the last value
  # wins.
  #
  # NOTE: `require "sorted_map/yaml"` is required to opt-in to this feature.
  #
  # ```
  # require "sorted_map/yaml"
  #
  # map = SortedMap(String, Int32).from_yaml("b: 2\na: 1\n")
  # map.keys # => ["a", "b"]
  # ```
  def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
    ctx.read_alias(node, self) do |obj|
      return obj
    end

    unless node.is_a?(YAML::Nodes::Mapping)
      node.raise "Expected mapping, not #{node.kind}"
    end

    map = new
    ctx.record_anchor(node, map)
    YAML::Schema::Core.each(node) do |key, value|
      map[K.new(ctx, key)] = V.new(ctx, value)
    end
    map
  end

  # Writes the map as a YAML mapping, in key order.
  #
  # NOTE: `require "sorted_map/yaml"` is required to opt-in to this feature.
  def to_yaml(yaml : YAML::Nodes::Builder) : Nil
    yaml.mapping(reference: self) do
      each do |key, value|
        key.to_yaml(yaml)
        value.to_yaml(yaml)
      end
    end
  end
end
