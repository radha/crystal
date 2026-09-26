require "json"
require "sorted_map"

class SortedMap(K, V)
  # Reads a map from a JSON object. Keys are read with the key type's
  # `from_json_object_key?`, as for `Hash`; when a key repeats, the last
  # value wins.
  #
  # NOTE: `require "sorted_map/json"` is required to opt-in to this feature.
  #
  # ```
  # require "sorted_map/json"
  #
  # map = SortedMap(String, Int32).from_json(%({"b": 2, "a": 1}))
  # map.keys # => ["a", "b"]
  # ```
  def self.new(pull : JSON::PullParser)
    map = new
    pull.read_object do |key, key_location|
      parsed_key = K.from_json_object_key?(key)
      unless parsed_key
        raise JSON::ParseException.new("Can't convert #{key.inspect} into #{K}", *key_location)
      end
      map[parsed_key] = V.new(pull)
    end
    map
  end

  # Writes the map as a JSON object, in key order. Keys are written with
  # `to_json_object_key`, as for `Hash`.
  #
  # NOTE: `require "sorted_map/json"` is required to opt-in to this feature.
  #
  # ```
  # SortedMap{2 => "b", 1 => "a"}.to_json # => %({"1":"a","2":"b"})
  # ```
  def to_json(json : JSON::Builder) : Nil
    json.object do
      each do |key, value|
        json.field key.to_json_object_key do
          value.to_json(json)
        end
      end
    end
  end
end
