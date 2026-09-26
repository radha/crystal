require "json"
require "sorted_set"

class SortedSet(T)
  # Reads a set from a JSON array; duplicates are kept once.
  #
  # NOTE: `require "sorted_set/json"` is required to opt-in to this feature.
  #
  # ```
  # require "sorted_set/json"
  #
  # SortedSet(Int32).from_json("[3, 1, 3]").to_a # => [1, 3]
  # ```
  def self.new(pull : JSON::PullParser)
    set = new
    pull.read_array do
      set << T.new(pull)
    end
    set
  end

  # Writes the set as a JSON array, in order.
  #
  # NOTE: `require "sorted_set/json"` is required to opt-in to this feature.
  def to_json(json : JSON::Builder) : Nil
    json.array do
      each &.to_json(json)
    end
  end
end
