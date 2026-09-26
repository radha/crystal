require "spec"
require "sorted_map/json"
require "sorted_map/yaml"
require "sorted_set/json"
require "sorted_set/yaml"

private class Holder
  include JSON::Serializable
  include YAML::Serializable

  property scores : SortedMap(String, Int32)
  property tags : SortedSet(String)

  def initialize(@scores, @tags)
  end
end

describe "SortedMap serialization" do
  describe "JSON" do
    it "writes an object in key order" do
      SortedMap{"b" => 2, "a" => 1}.to_json.should eq(%({"a":1,"b":2}))
      SortedMap(Int32, String).new.to_json.should eq("{}")
    end

    it "converts non-string keys like Hash does" do
      map = SortedMap{10 => [1.5], 2 => [] of Float64}
      json = map.to_json
      json.should eq(%({"2":[],"10":[1.5]}))
      SortedMap(Int32, Array(Float64)).from_json(json).should eq(map)
    end

    it "reads an object, last duplicate winning" do
      map = SortedMap(String, Int32).from_json(%({"z": 1, "a": 2, "z": 3}))
      map.to_a.should eq([{"a", 2}, {"z", 3}])
    end

    it "rejects keys it can't convert" do
      expect_raises(JSON::ParseException, %(Can't convert "x" into Int32)) do
        SortedMap(Int32, Int32).from_json(%({"x": 1}))
      end
    end

    it "round-trips a large map" do
      map = SortedMap.new((0...5000).map { |i| {i, i.to_s} })
      back = SortedMap(Int32, String).from_json(map.to_json)
      back.should eq(map)
      back.check_invariants
    end
  end

  describe "YAML" do
    it "writes a mapping in key order and reads it back" do
      map = SortedMap{"b" => 2, "a" => 1}
      yaml = map.to_yaml
      yaml.should eq("---\na: 1\nb: 2\n")
      SortedMap(String, Int32).from_yaml(yaml).should eq(map)
    end

    it "rejects a sequence" do
      expect_raises(YAML::ParseException, "Expected mapping, not sequence") do
        SortedMap(String, Int32).from_yaml("- 1\n")
      end
    end

    it "resolves aliases to the same map" do
      maps = Array(SortedMap(String, Int32)).from_yaml("- &m\n  a: 1\n- *m\n")
      maps[0].should be(maps[1])
    end
  end
end

describe "SortedSet serialization" do
  it "writes and reads JSON arrays" do
    set = SortedSet{3, 1, 2}
    set.to_json.should eq("[1,2,3]")
    SortedSet(Int32).from_json("[3, 1, 3, 2]").should eq(set)
  end

  it "writes and reads YAML sequences" do
    set = SortedSet{"b", "a"}
    yaml = set.to_yaml
    yaml.should eq("---\n- a\n- b\n")
    SortedSet(String).from_yaml(yaml).should eq(set)
    expect_raises(YAML::ParseException, "Expected sequence, not mapping") do
      SortedSet(String).from_yaml("a: 1\n")
    end
  end
end

describe "SortedMap and SortedSet as Serializable fields" do
  it "round-trips through JSON and YAML" do
    holder = Holder.new(SortedMap{"bo" => 3, "al" => 5}, SortedSet{"x", "a"})

    json = holder.to_json
    json.should eq(%({"scores":{"al":5,"bo":3},"tags":["a","x"]}))
    from_json = Holder.from_json(json)
    from_json.scores.should eq(holder.scores)
    from_json.tags.should eq(holder.tags)

    from_yaml = Holder.from_yaml(holder.to_yaml)
    from_yaml.scores.should eq(holder.scores)
    from_yaml.tags.should eq(holder.tags)
  end
end
