require "sorted_map"

# A `SortedSet` is a set that keeps its elements in ascending order, stored
# in a [B-tree](https://en.wikipedia.org/wiki/B-tree).
#
# Adding, removing and looking up an element take O(log n). Unlike `Set`, a
# `SortedSet` iterates in order and answers ordered questions: the smallest
# or largest element, the closest element at or below or above a probe
# (`floor`, `ceiling`, `lower`, `higher`), and every element within a range
# (`each(range)`). Set operations such as `|` and `&` walk both sets in
# order and run in O(n + m).
#
# ```
# require "sorted_set"
#
# set = SortedSet{5, 1, 3}
# set << 4
# set.to_a                        # => [1, 3, 4, 5]
# set.floor(2)                    # => 1
# set.higher(4)                   # => 5
# set.each(2..4).to_a             # => [3, 4]
# (set & SortedSet{3, 5, 7}).to_a # => [3, 5]
# ```
#
# Elements are ordered with `<=>`, and two elements are the same element
# when `<=>` returns zero. The element type must define `<=>`.
#
# Adding or removing elements while iterating the set is memory safe, but
# the iteration may then skip or repeat elements.
#
# NOTE: To use `SortedSet`, you must explicitly import it with `require "sorted_set"`
class SortedSet(T)
  include Enumerable(T)
  include Iterable(T)

  @map : SortedMap(T, Nil)

  # Creates an empty set.
  def initialize
    @map = SortedMap(T, Nil).new
  end

  # :nodoc:
  def initialize(@map : SortedMap(T, Nil))
  end

  # Creates a set from the *elements*, in any order, in O(n log n).
  #
  # ```
  # SortedSet.new([3, 1, 2, 1]).to_a # => [1, 2, 3]
  # ```
  def self.new(elements : Enumerable(T))
    sorted = elements.to_a
    sorted.sort! { |a, b| SortedMap(T, Nil).compare(a, b) }
    from_sorted(sorted)
  end

  # Creates a set from *elements* that are already in ascending order, in
  # O(n). Adjacent duplicates are kept once.
  #
  # Raises `ArgumentError` if an element is smaller than the one before it.
  def self.from_sorted(elements : Enumerable(T)) : SortedSet(T)
    builder = SortedMap::Builder(T, Nil).new
    elements.each { |element| builder.push(element, nil, check: true) }
    SortedSet(T).new(builder.build)
  end

  # Returns the number of elements.
  def size : Int32
    @map.size
  end

  # Returns `true` if the set has no elements.
  def empty? : Bool
    @map.empty?
  end

  # Removes every element.
  def clear : self
    @map.clear
    self
  end

  # Adds *object* to the set and returns `self`.
  #
  # ```
  # set = SortedSet(Int32).new
  # set << 2 << 1 << 2
  # set.to_a # => [1, 2]
  # ```
  def add(object : T) : self
    @map[object] = nil
    self
  end

  # :ditto:
  def <<(object : T) : self
    add(object)
  end

  # Adds *object* and returns `true` if the set did not have it yet;
  # returns `false` otherwise.
  def add?(object : T) : Bool
    size = @map.size
    @map[object] = nil
    @map.size != size
  end

  # Adds every element of *elements* and returns `self`.
  def concat(elements : Enumerable(T)) : self
    elements.each { |element| add(element) }
    self
  end

  # Returns `true` if the set has *object*.
  def includes?(object : T) : Bool
    @map.has_key?(object)
  end

  # Removes *object* and returns `true` if the set had it; returns `false`
  # otherwise.
  def delete(object : T) : Bool
    size = @map.size
    @map.delete(object)
    @map.size != size
  end

  # Removes the elements within *range* and returns how many it removed.
  # Either end of the range may be `nil` for an open end.
  def delete_range(range : Range) : Int32
    @map.delete_range(range)
  end

  # Returns the smallest element. Raises `Enumerable::EmptyError` if the set
  # is empty.
  def first : T
    @map.first_key
  end

  # Returns the smallest element, or `nil` if the set is empty.
  def first? : T?
    @map.first_key?
  end

  # Returns the largest element. Raises `Enumerable::EmptyError` if the set
  # is empty.
  def last : T
    @map.last_key
  end

  # Returns the largest element, or `nil` if the set is empty.
  def last? : T?
    @map.last_key?
  end

  # Removes and returns the smallest element. Raises
  # `Enumerable::EmptyError` if the set is empty.
  def shift : T
    @map.shift[0]
  end

  # Removes and returns the smallest element, or returns `nil` if the set is
  # empty.
  def shift? : T?
    @map.shift?.try &.[0]
  end

  # Removes and returns the largest element. Raises `Enumerable::EmptyError`
  # if the set is empty.
  def pop : T
    @map.pop[0]
  end

  # Removes and returns the largest element, or returns `nil` if the set is
  # empty.
  def pop? : T?
    @map.pop?.try &.[0]
  end

  # Returns the largest element at or below *object*, or `nil` if there is
  # none.
  #
  # ```
  # SortedSet{10, 20}.floor(15) # => 10
  # ```
  def floor(object : T) : T?
    @map.floor_key(object)
  end

  # Returns the smallest element at or above *object*, or `nil` if there is
  # none.
  #
  # ```
  # SortedSet{10, 20}.ceiling(15) # => 20
  # ```
  def ceiling(object : T) : T?
    @map.ceiling_key(object)
  end

  # Returns the largest element strictly below *object*, or `nil` if there
  # is none.
  def lower(object : T) : T?
    @map.lower_key(object)
  end

  # Returns the smallest element strictly above *object*, or `nil` if there
  # is none.
  def higher(object : T) : T?
    @map.higher_key(object)
  end

  # Yields each element in ascending order.
  def each(& : T ->) : Nil
    @map.each { |key, _| yield key }
  end

  # Returns an iterator over the elements in ascending order.
  def each : Iterator(T)
    @map.each.map(&.[0])
  end

  # Yields each element within *range* in ascending order. Either end of the
  # range may be `nil` for an open end.
  #
  # ```
  # SortedSet{1, 3, 5, 7}.each(2..6) { |x| puts x } # prints 3 and 5
  # ```
  def each(range : Range, & : T ->) : Nil
    @map.each(range) { |key, _| yield key }
  end

  # Returns an iterator over the elements within *range*, in ascending
  # order.
  def each(range : Range) : Iterator(T)
    @map.each(range).map(&.[0])
  end

  # Yields each element in descending order.
  def reverse_each(& : T ->) : Nil
    @map.reverse_each { |key, _| yield key }
  end

  # Returns an iterator over the elements in descending order.
  def reverse_each : Iterator(T)
    @map.reverse_each.map(&.[0])
  end

  # Yields each element within *range* in descending order.
  def reverse_each(range : Range, & : T ->) : Nil
    @map.reverse_each(range) { |key, _| yield key }
  end

  # Returns an iterator over the elements within *range*, in descending
  # order.
  def reverse_each(range : Range) : Iterator(T)
    @map.reverse_each(range).map(&.[0])
  end

  # Returns the elements in ascending order.
  def to_a : Array(T)
    @map.keys
  end

  # Returns a new set with the elements of both sets.
  #
  # ```
  # SortedSet{1, 3} | SortedSet{2, 3} # => SortedSet{1, 2, 3}
  # ```
  def |(other : SortedSet(T)) : SortedSet(T)
    merge(other, left: true, both: true, right: true)
  end

  # Returns a new set with the elements that are in both sets.
  #
  # ```
  # SortedSet{1, 2, 3} & SortedSet{2, 3, 4} # => SortedSet{2, 3}
  # ```
  def &(other : SortedSet(T)) : SortedSet(T)
    merge(other, left: false, both: true, right: false)
  end

  # Returns a new set with the elements of this set that are not in
  # *other*.
  #
  # ```
  # SortedSet{1, 2, 3} - SortedSet{2} # => SortedSet{1, 3}
  # ```
  def -(other : SortedSet(T)) : SortedSet(T)
    merge(other, left: true, both: false, right: false)
  end

  # Returns a new set with the elements that are in exactly one of the two
  # sets.
  #
  # ```
  # SortedSet{1, 2, 3} ^ SortedSet{2, 3, 4} # => SortedSet{1, 4}
  # ```
  def ^(other : SortedSet(T)) : SortedSet(T)
    merge(other, left: true, both: false, right: true)
  end

  # Walks both sets in order and keeps the elements only in `self` (*left*),
  # in both (*both*), or only in *other* (*right*).
  private def merge(other : SortedSet(T), *, left : Bool, both : Bool, right : Bool) : SortedSet(T)
    builder = SortedMap::Builder(T, Nil).new
    each_merged(other) do |element, side|
      keep = case side
             when .negative? then left
             when .zero?     then both
             else                 right
             end
      builder.push(element, nil, check: false) if keep
    end
    SortedSet(T).new(builder.build)
  end

  # Yields each element of the two sets in order with -1 when only `self`
  # has it, 0 when both do, and 1 when only *other* does.
  private def each_merged(other : SortedSet(T), &) : Nil
    mine = each
    theirs = other.each
    a = mine.next
    b = theirs.next
    while true
      if a.is_a?(Iterator::Stop)
        until b.is_a?(Iterator::Stop)
          yield b, 1
          b = theirs.next
        end
        return
      end
      if b.is_a?(Iterator::Stop)
        until a.is_a?(Iterator::Stop)
          yield a, -1
          a = mine.next
        end
        return
      end
      c = SortedMap(T, Nil).compare(a, b)
      if c < 0
        yield a, -1
        a = mine.next
      elsif c > 0
        yield b, 1
        b = theirs.next
      else
        yield a, 0
        a = mine.next
        b = theirs.next
      end
    end
  end

  # Returns `true` if every element of this set is in *other*.
  def subset_of?(other : SortedSet(T)) : Bool
    return false if size > other.size
    each_merged(other) { |_, side| return false if side < 0 }
    true
  end

  # Returns `true` if this set is a subset of *other* and smaller than it.
  def proper_subset_of?(other : SortedSet(T)) : Bool
    size < other.size && subset_of?(other)
  end

  # Returns `true` if every element of *other* is in this set.
  def superset_of?(other : SortedSet(T)) : Bool
    other.subset_of?(self)
  end

  # Returns `true` if this set is a superset of *other* and larger than it.
  def proper_superset_of?(other : SortedSet(T)) : Bool
    other.proper_subset_of?(self)
  end

  # Returns `true` if the two sets have an element in common.
  def intersects?(other : SortedSet(T)) : Bool
    each_merged(other) { |_, side| return true if side == 0 }
    false
  end

  # Returns `true` if *other* has the same elements.
  def ==(other : SortedSet) : Bool
    @map == other.@map
  end

  # See `Object#hash(hasher)`
  def hash(hasher)
    @map.hash(hasher)
  end

  # Returns a copy of the set with the same elements.
  def dup : self
    SortedSet(T).new(@map.dup)
  end

  # Returns a copy of the set whose elements are cloned too.
  def clone : self
    SortedSet(T).new(@map.clone)
  end

  def to_s(io : IO) : Nil
    io << "SortedSet{"
    join io, ", ", &.inspect(io)
    io << '}'
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end

  def pretty_print(pp) : Nil
    pp.list("SortedSet{", self, "}")
  end

  # :nodoc:
  def check_invariants : Nil
    @map.check_invariants
  end
end
