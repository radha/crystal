# A `DisjointSet` (union-find) partitions elements into disjoint sets, with
# near-constant-time `union` of two sets and `find` of an element's set.
# Typical uses are connected components, Kruskal's minimum spanning tree,
# grouping equivalent items and cycle detection.
#
# ```
# require "disjoint_set"
#
# friends = DisjointSet(String).new
# friends.union("alice", "bob")
# friends.union("carol", "dave")
# friends.same?("alice", "bob")   # => true
# friends.same?("alice", "carol") # => false
# friends.union("bob", "carol")
# friends.set_size("dave") # => 4
# friends.set_count        # => 1
# ```
#
# `union` adds elements it has not seen; `add` adds a singleton explicitly.
# Every set has one *representative* element, returned by `find`; two
# elements are in the same set exactly when they have the same
# representative. Which element represents a set is unspecified and can
# change after a `union`.
#
# ### Dense integer elements
#
# `DisjointSet(Int32)` is specialized for graph algorithms whose elements
# are already indices: the elements are always the dense range
# `0...size`, stored without any hash table. `new(size)` creates that many
# singletons, and naming a larger index (in `union` or `add`) grows the
# range to include it, so `union(9, 2)` on an empty set creates the
# elements `0..9`. Negative elements raise `ArgumentError`. For sparse
# integers use another integer type, such as `DisjointSet(Int64)`, which
# keys a hash table like any other type.
#
# ```
# require "disjoint_set"
#
# components = DisjointSet(Int32).new(5)
# components.union(0, 1)
# components.union(3, 4)
# components.set_count # => 3
# components.sets      # => [[0, 1], [2], [3, 4]]
# ```
#
# Operations use union by size and path halving, so any sequence of `m`
# operations on `n` elements takes `O(m α(n))` time, where `α` is the
# inverse Ackermann function (below 5 for any practical `n`).
#
# NOTE: To use `DisjointSet`, you must explicitly import it with `require "disjoint_set"`
class DisjointSet(T)
  include Enumerable(T)

  # `@parent[i]` is the parent of element `i`, or, for a root, the negated
  # size of its set. One array instead of parent + size halves the memory a
  # `find` touches.
  @parent : Array(Int32)
  @set_count : Int32

  # Element <-> index maps for every `T` but `Int32`, whose elements are
  # their own indices (the maps then stay empty).
  @index : Hash(T, Int32)
  @elements : Array(T)

  # Creates an empty disjoint set.
  def initialize
    @parent = [] of Int32
    @set_count = 0
    @index = {} of T => Int32
    @elements = [] of T
  end

  # Creates a `DisjointSet(Int32)` of the singletons `0...size`.
  #
  # ```
  # set = DisjointSet(Int32).new(3)
  # set.to_a # => [0, 1, 2]
  # ```
  #
  # Raises `ArgumentError` if *size* is negative.
  def self.new(size : Int) : self
    {% raise "DisjointSet(#{T}).new(size) is only defined for DisjointSet(Int32); use DisjointSet(#{T}).new(elements)" unless T == Int32 %}
    raise ArgumentError.new("Negative size: #{size}") if size < 0
    set = new
    set.grow(size.to_i32)
    set
  end

  # Creates a disjoint set where each of *elements* is a singleton
  # (duplicates are added once).
  #
  # ```
  # set = DisjointSet.new(%w[a b c])
  # set.set_count # => 3
  # ```
  def initialize(elements : Enumerable(T))
    initialize
    elements.each { |element| add(element) }
  end

  # Adds *element* as a singleton set unless it is already present. Returns
  # `true` if it was added.
  #
  # For `DisjointSet(Int32)` this grows the range `0...size` to include
  # *element*, adding every missing index as a singleton.
  def add(element : T) : Bool
    {% if T == Int32 %}
      check_index(element)
      return false if element < @parent.size
      grow(element + 1)
      true
    {% else %}
      return false if @index.has_key?(element)
      index_for(element)
      true
    {% end %}
  end

  # Adds *element* as a singleton set unless it is already present and
  # returns `self`.
  def <<(element : T) : self
    add(element)
    self
  end

  # Merges the sets of *a* and *b*, adding either element first if it is not
  # present. Returns `true` if they were in different sets, `false` if they
  # were already in the same set.
  #
  # ```
  # set = DisjointSet(Int32).new(3)
  # set.union(0, 1) # => true
  # set.union(1, 0) # => false
  # ```
  def union(a : T, b : T) : Bool
    a_root = root(index_for(a))
    b_root = root(index_for(b))
    return false if a_root == b_root

    parent = @parent.to_unsafe
    # Union by size: roots hold negated sizes, so the larger set is the
    # more negative one.
    a_root, b_root = b_root, a_root if parent[a_root] > parent[b_root]
    parent[a_root] += parent[b_root]
    parent[b_root] = a_root
    @set_count -= 1
    true
  end

  # Returns the representative of the set containing *element*.
  #
  # Raises `KeyError` if *element* is not present.
  def find(element : T) : T
    index = index_of?(element) || raise KeyError.new("Missing disjoint set element: #{element.inspect}")
    element_at(root(index))
  end

  # Returns the representative of the set containing *element*, or `nil`
  # if *element* is not present.
  def find?(element : T) : T?
    index = index_of?(element) || return nil
    element_at(root(index))
  end

  # Returns `true` if *a* and *b* are in the same set. An element that is
  # not present is only in the same set as itself.
  def same?(a : T, b : T) : Bool
    a_index = index_of?(a)
    b_index = index_of?(b)
    return a == b unless a_index && b_index
    root(a_index) == root(b_index)
  end

  # Returns `true` if *element* is present.
  def includes?(element : T) : Bool
    !index_of?(element).nil?
  end

  # Returns the number of elements in the set containing *element*.
  #
  # Raises `KeyError` if *element* is not present.
  def set_size(element : T) : Int32
    index = index_of?(element) || raise KeyError.new("Missing disjoint set element: #{element.inspect}")
    -@parent.to_unsafe[root(index)]
  end

  # Returns the elements in the same set as *element* (including itself),
  # in insertion order. Takes `O(size)` time.
  #
  # Raises `KeyError` if *element* is not present.
  def set_of(element : T) : Array(T)
    index = index_of?(element) || raise KeyError.new("Missing disjoint set element: #{element.inspect}")
    target = root(index)
    members = Array(T).new(-@parent.to_unsafe[target])
    @parent.size.times do |i|
      members << element_at(i) if root(i) == target
    end
    members
  end

  # Returns the number of disjoint sets.
  def set_count : Int32
    @set_count
  end

  # Returns the number of elements.
  def size : Int32
    @parent.size
  end

  # Returns `true` if there are no elements.
  def empty? : Bool
    @parent.empty?
  end

  # Yields each element in insertion order (ascending for
  # `DisjointSet(Int32)`).
  def each(& : T ->) : Nil
    @parent.size.times do |i|
      yield element_at(i)
    end
  end

  # Returns every set as an array of its elements. Sets are ordered by
  # their first element and elements by insertion order (ascending for
  # `DisjointSet(Int32)`).
  #
  # ```
  # set = DisjointSet.new(%w[a b c d])
  # set.union("d", "a")
  # set.sets # => [["a", "d"], ["b"], ["c"]]
  # ```
  def sets : Array(Array(T))
    groups = Array(Array(T)).new(@set_count)
    slot = Array(Int32).new(@parent.size, -1)
    @parent.size.times do |i|
      r = root(i)
      group = slot.to_unsafe[r]
      if group < 0
        group = slot.to_unsafe[r] = groups.size
        groups << Array(T).new(-@parent.to_unsafe[r])
      end
      groups.to_unsafe[group] << element_at(i)
    end
    groups
  end

  # Yields each set as an array of its elements, in the order of `sets`.
  def each_set(& : Array(T) ->) : Nil
    sets.each { |set| yield set }
  end

  # Removes every element.
  def clear : self
    @parent.clear
    @set_count = 0
    @index.clear
    @elements.clear
    self
  end

  # Returns a copy that can be changed independently of `self`. Elements
  # are not duplicated.
  def dup : self
    copy = self.class.new
    copy.initialize_copy(@parent.dup, @set_count, @index.dup, @elements.dup)
    copy
  end

  # Returns `true` if both partition the same elements, inserted in the
  # same order, into the same sets.
  def ==(other : DisjointSet) : Bool
    return false unless size == other.size && set_count == other.set_count
    return false unless to_a == other.to_a
    sets == other.sets
  end

  def inspect(io : IO) : Nil
    io << "DisjointSet("
    sets.join(io, ", ") do |set, io|
      io << '{'
      set.join(io, ", ") { |element, io| element.inspect(io) }
      io << '}'
    end
    io << ')'
  end

  def to_s(io : IO) : Nil
    inspect(io)
  end

  protected def initialize_copy(@parent, @set_count, @index, @elements) : Nil
  end

  protected def grow(new_size : Int32) : Nil
    old_size = @parent.size
    return if new_size <= old_size
    (new_size - old_size).times { @parent << -1 }
    @set_count += new_size - old_size
  end

  # Finds the root of *index*, halving the path on the way: every visited
  # node is pointed at its grandparent.
  @[AlwaysInline]
  private def root(index : Int32) : Int32
    parent = @parent.to_unsafe
    loop do
      up = parent[index]
      return index if up < 0
      grand = parent[up]
      return up if grand < 0
      parent[index] = grand
      index = grand
    end
  end

  # Returns the index of *element*, adding it first if it is not present.
  @[AlwaysInline]
  private def index_for(element : T) : Int32
    {% if T == Int32 %}
      check_index(element)
      grow(element + 1) if element >= @parent.size
      element
    {% else %}
      @index.put_if_absent(element) do
        @elements << element
        @parent << -1
        @set_count += 1
        @parent.size - 1
      end
    {% end %}
  end

  @[AlwaysInline]
  private def index_of?(element : T) : Int32?
    {% if T == Int32 %}
      element if 0 <= element < @parent.size
    {% else %}
      @index[element]?
    {% end %}
  end

  @[AlwaysInline]
  private def element_at(index : Int32) : T
    {% if T == Int32 %}
      index
    {% else %}
      @elements.unsafe_fetch(index)
    {% end %}
  end

  private def check_index(element : Int32) : Nil
    raise ArgumentError.new("Negative DisjointSet(Int32) element: #{element}") if element < 0
  end
end
