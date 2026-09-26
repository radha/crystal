# A `SortedMap` is a dictionary that keeps its keys in ascending order,
# stored in a [B-tree](https://en.wikipedia.org/wiki/B-tree).
#
# Lookups, insertions and deletions take O(log n). Unlike `Hash`, a
# `SortedMap` iterates its entries in key order and answers ordered
# questions: the smallest or largest key (`first`, `last`), the closest key
# at or below or above a probe (`floor`, `ceiling`, `lower`, `higher`), and
# every entry within a range of keys (`each(range)`).
#
# ```
# require "sorted_map"
#
# prices = SortedMap(String, Int32).new
# prices["pear"] = 3
# prices["apple"] = 5
# prices["fig"] = 8
#
# prices.keys                # => ["apple", "fig", "pear"]
# prices.first               # => {"apple", 5}
# prices.ceiling("banana")   # => {"fig", 8}
# prices.each("b".."g").to_a # => [{"fig", 8}]
# prices.delete("fig")       # => 8
# prices.to_a                # => [{"apple", 5}, {"pear", 3}]
# ```
#
# Keys are ordered with `<=>`, and two keys are the same key when `<=>`
# returns zero. The key type must define `<=>`. For a different order, wrap
# the key in a type whose `<=>` implements it. A comparison that returns
# `nil` (such as one involving `Float64::NAN`) raises `ArgumentError`.
#
# Building a map from a collection with `SortedMap.new(entries)` sorts the
# entries once and builds the tree bottom-up, which is faster than inserting
# them one by one. `SortedMap.from_sorted` skips the sort when the entries
# are already in key order.
#
# Adding or removing entries while iterating the map is memory safe, but the
# iteration may then skip or repeat entries.
#
# NOTE: To use `SortedMap`, you must explicitly import it with `require "sorted_map"`
class SortedMap(K, V)
  include Enumerable({K, V})
  include Iterable({K, V})

  # Most keys a node holds. Nodes other than the root hold between
  # `MIN_LEN` and `CAPACITY` keys; internal nodes have one more child than
  # keys. These match Rust's `BTreeMap`.
  private CAPACITY = 11
  private MIN_LEN  =  5
  # Index of the key a full node moves up to its parent when it splits.
  private MIDDLE = 5
  # Deepest tree the cursors can walk: 2 * 6**31 keys, more than fit in
  # memory.
  private MAX_LEVELS = 32

  # :nodoc:
  #
  # A leaf node. Slots at or past `len` are cleared so that removed keys and
  # values are not kept alive by the GC.
  class Node(K, V)
    @len = 0
    @keys = uninitialized StaticArray(K, 11)
    @vals = uninitialized StaticArray(V, 11)

    property len : Int32

    @[AlwaysInline]
    def keys : Pointer(K)
      pointerof(@keys).as(Pointer(K))
    end

    @[AlwaysInline]
    def vals : Pointer(V)
      pointerof(@vals).as(Pointer(V))
    end
  end

  # :nodoc:
  #
  # An internal node: `edges[i]` holds the keys ordered before `keys[i]`,
  # and `edges[len]` the keys after the last one.
  class Internal(K, V) < Node(K, V)
    @edges = uninitialized StaticArray(Node(K, V), 12)

    @[AlwaysInline]
    def edges : Pointer(Node(K, V))
      pointerof(@edges).as(Pointer(Node(K, V)))
    end
  end

  # The root is a leaf while `@height` is zero. Leaves sit `@height` levels
  # below the root, and a node's kind follows from its level, so the tree is
  # walked with unchecked casts.
  @root : Node(K, V)
  @height = 0
  @size = 0

  # Creates an empty map.
  #
  # ```
  # map = SortedMap(Int32, String).new
  # map[2] = "b"
  # map[1] = "a"
  # map.to_a # => [{1, "a"}, {2, "b"}]
  # ```
  def initialize
    {% raise "SortedMap(#{K}, #{V}) needs a key type that defines `<=>`" unless (K.union? ? K.union_types.all?(&.has_method?("<=>")) : K.has_method?("<=>")) %}
    @root = Node(K, V).new
  end

  # Creates a map from the *entries*, key-value tuples in any order. When a
  # key appears more than once, the last entry wins, as with `Hash`.
  #
  # It sorts the entries and builds the tree bottom-up, in O(n log n).
  #
  # ```
  # map = SortedMap.new({3 => "c", 1 => "a", 2 => "b"})
  # map.keys # => [1, 2, 3]
  # ```
  def self.new(entries : Enumerable({K, V}))
    sorted = entries.to_a
    sorted.sort! { |a, b| compare(a[0], b[0]) }
    from_sorted(sorted)
  end

  # Creates a map from *entries* that are already in ascending key order, in
  # O(n). When adjacent entries have the same key, the last one wins.
  #
  # Raises `ArgumentError` if a key is smaller than the key before it.
  #
  # ```
  # SortedMap.from_sorted([{1, "a"}, {2, "b"}]).size # => 2
  # SortedMap.from_sorted([{2, "b"}, {1, "a"}])      # raises ArgumentError
  # ```
  def self.from_sorted(entries : Enumerable({K, V})) : SortedMap(K, V)
    builder = Builder(K, V).new
    entries.each { |key, value| builder.push(key, value, check: true) }
    builder.build
  end

  # :nodoc:
  def self.compare(a : K, b : K) : Int32
    c = a <=> b
    c || raise ArgumentError.new("Comparison of #{a.inspect} and #{b.inspect} failed")
  end

  @[AlwaysInline]
  private def cmp(a : K, b : K) : Int32
    SortedMap(K, V).compare(a, b)
  end

  @[AlwaysInline]
  private def internal(node : Node(K, V)) : Internal(K, V)
    node.unsafe_as(Internal(K, V))
  end

  # Returns the number of entries.
  def size : Int32
    @size
  end

  # Returns `true` if the map has no entries.
  def empty? : Bool
    @size == 0
  end

  # Removes every entry.
  def clear : self
    @root = Node(K, V).new
    @height = 0
    @size = 0
    self
  end

  # Returns the index of the first key in *node* that is not smaller than
  # *key*, and whether that key equals *key*.
  @[AlwaysInline]
  private def search(node : Node(K, V), key : K) : {Int32, Bool}
    SortedMap(K, V).search(node, key)
  end

  # :nodoc:
  def self.search(node : Node(K, V), key : K) : {Int32, Bool}
    keys = node.keys
    len = node.len
    i = 0
    while i < len
      c = compare(key, keys[i])
      return {i, true} if c == 0
      break if c < 0
      i += 1
    end
    {i, false}
  end

  # :nodoc:
  #
  # Index of the first key in *node* greater than *key*.
  def self.upper_bound(node : Node(K, V), key : K) : Int32
    keys = node.keys
    len = node.len
    i = 0
    while i < len
      break if compare(key, keys[i]) < 0
      i += 1
    end
    i
  end

  private def find(key : K) : {Node(K, V), Int32}?
    node = @root
    height = @height
    while true
      i, found = search(node, key)
      return {node, i} if found
      return nil if height == 0
      node = internal(node).edges[i]
      height -= 1
    end
  end

  # Returns the value for *key*, or `nil` if the map has no such key.
  #
  # ```
  # map = SortedMap{1 => "a"}
  # map[1]? # => "a"
  # map[2]? # => nil
  # ```
  def []?(key : K) : V?
    if entry = find(key)
      node, i = entry
      node.vals[i]
    end
  end

  # Returns the value for *key*. Raises `KeyError` if the map has no such
  # key.
  def [](key : K) : V
    fetch(key) { raise KeyError.new "Missing sorted map key: #{key.inspect}" }
  end

  # Returns the value for *key*, or yields *key* and returns the block's
  # value if the map has no such key.
  #
  # ```
  # map = SortedMap{1 => "a"}
  # map.fetch(2) { |key| "none for #{key}" } # => "none for 2"
  # ```
  def fetch(key : K, &)
    if entry = find(key)
      node, i = entry
      node.vals[i]
    else
      yield key
    end
  end

  # Returns the value for *key*, or *default* if the map has no such key.
  def fetch(key : K, default)
    fetch(key) { default }
  end

  # Returns `true` if the map has *key*.
  def has_key?(key : K) : Bool
    !find(key).nil?
  end

  # Returns `true` if some entry has *value*. This walks every entry.
  def has_value?(value) : Bool
    each { |_, v| return true if v == value }
    false
  end

  # Sets the value for *key*, replacing any existing value.
  #
  # ```
  # map = SortedMap(String, Int32).new
  # map["a"] = 1
  # map["a"] = 2
  # map.to_a # => [{"a", 2}]
  # ```
  def []=(key : K, value : V) : V
    if split = insert(@root, @height, key, value)
      grow_root(*split)
    end
    value
  end

  # Sets the value for *key* only if the map does not have it yet, and
  # returns the value the map holds for *key* afterwards.
  #
  # ```
  # map = SortedMap{1 => "a"}
  # map.put_if_absent(1, "z") # => "a"
  # map.put_if_absent(2, "b") # => "b"
  # ```
  def put_if_absent(key : K, value : V) : V
    put_if_absent(key) { value }
  end

  # Like `put_if_absent(key, value)`, but only calls the block for the value
  # when *key* is missing.
  def put_if_absent(key : K, & : K -> V) : V
    if entry = find(key)
      node, i = entry
      node.vals[i]
    else
      self[key] = yield key
    end
  end

  private def grow_root(key : K, value : V, right : Node(K, V)) : Nil
    root = Internal(K, V).new
    root.keys[0] = key
    root.vals[0] = value
    root.edges[0] = @root
    root.edges[1] = right
    root.len = 1
    @root = root
    @height += 1
  end

  # Inserts or replaces *key* in the subtree under *node*. When *node* has
  # to split, returns the key and value that move up and the new right
  # sibling.
  private def insert(node : Node(K, V), height : Int32, key : K, value : V) : {K, V, Node(K, V)}?
    i, found = search(node, key)
    if found
      node.vals[i] = value
      return nil
    end

    if height == 0
      @size += 1
      if node.len < CAPACITY
        insert_at(node, i, key, value)
        return nil
      end
      right = Node(K, V).new
      up_key, up_value = split_keys(node, right)
      if i <= MIDDLE
        insert_at(node, i, key, value)
      else
        insert_at(right, i - MIDDLE - 1, key, value)
      end
      return {up_key, up_value, right}
    end

    parent = internal(node)
    split = insert(parent.edges[i], height - 1, key, value)
    return nil unless split
    child_key, child_value, child_right = split

    if parent.len < CAPACITY
      insert_edge_at(parent, i, child_key, child_value, child_right)
      return nil
    end
    right = Internal(K, V).new
    up_key, up_value = split_keys(parent, right)
    right.edges.copy_from(parent.edges + MIDDLE + 1, CAPACITY - MIDDLE)
    (parent.edges + MIDDLE + 1).clear(CAPACITY - MIDDLE)
    if i <= MIDDLE
      insert_edge_at(parent, i, child_key, child_value, child_right)
    else
      insert_edge_at(right, i - MIDDLE - 1, child_key, child_value, child_right)
    end
    {up_key, up_value, right}
  end

  # Moves the keys after `MIDDLE` of the full *node* into the empty *right*
  # and returns the middle key and value, which leave *node*.
  private def split_keys(node : Node(K, V), right : Node(K, V)) : {K, V}
    right_len = CAPACITY - MIDDLE - 1
    right.keys.copy_from(node.keys + MIDDLE + 1, right_len)
    right.vals.copy_from(node.vals + MIDDLE + 1, right_len)
    right.len = right_len
    key = node.keys[MIDDLE]
    value = node.vals[MIDDLE]
    (node.keys + MIDDLE).clear(CAPACITY - MIDDLE)
    (node.vals + MIDDLE).clear(CAPACITY - MIDDLE)
    node.len = MIDDLE
    {key, value}
  end

  private def insert_at(node : Node(K, V), i : Int32, key : K, value : V) : Nil
    len = node.len
    (node.keys + i + 1).move_from(node.keys + i, len - i)
    (node.vals + i + 1).move_from(node.vals + i, len - i)
    node.keys[i] = key
    node.vals[i] = value
    node.len = len + 1
  end

  # Inserts *key* at index *i* of *node* and *edge* as the child right
  # after it.
  private def insert_edge_at(node : Internal(K, V), i : Int32, key : K, value : V, edge : Node(K, V)) : Nil
    edges = node.edges
    (edges + i + 2).move_from(edges + i + 1, node.len - i)
    edges[i + 1] = edge
    insert_at(node, i, key, value)
  end

  # Removes *key* and returns its value, or `nil` if the map has no such
  # key.
  #
  # ```
  # map = SortedMap{1 => "a", 2 => "b"}
  # map.delete(1) # => "a"
  # map.delete(1) # => nil
  # map.to_a      # => [{2, "b"}]
  # ```
  def delete(key : K) : V?
    delete(key) { nil }
  end

  # Removes *key* and returns its value, or yields *key* and returns the
  # block's value if the map has no such key.
  def delete(key : K, &)
    if entry = remove(@root, @height, key)
      shrink_root
      entry[1]
    else
      yield key
    end
  end

  # Removes the entries whose keys fall within *range* and returns how many
  # it removed. Either end of the range may be `nil` for an open end.
  #
  # ```
  # map = SortedMap.new((1..10).map { |i| {i, i * i} })
  # map.delete_range(3..8) # => 6
  # map.keys               # => [1, 2, 9, 10]
  # ```
  def delete_range(range : Range) : Int32
    doomed = [] of K
    each(range) { |key, _| doomed << key }
    doomed.each { |key| delete(key) }
    doomed.size
  end

  private def shrink_root : Nil
    if @height > 0 && @root.len == 0
      @root = internal(@root).edges[0]
      @height -= 1
    end
  end

  private def remove(node : Node(K, V), height : Int32, key : K) : {K, V}?
    i, found = search(node, key)
    if height == 0
      return nil unless found
      @size -= 1
      return remove_at(node, i)
    end

    parent = internal(node)
    if found
      # Replace the key with its predecessor, the largest key in the
      # subtree to its left, which always sits in a leaf.
      pred_key, pred_value = remove_edge(parent.edges[i], height - 1, last: true)
      entry = {node.keys[i], node.vals[i]}
      node.keys[i] = pred_key
      node.vals[i] = pred_value
      @size -= 1
    else
      entry = remove(parent.edges[i], height - 1, key)
    end
    rebalance(parent, i, height - 1) if entry
    entry
  end

  # Removes and returns the smallest (or, with *last*, the largest) entry
  # in the non-empty subtree under *node*.
  private def remove_edge(node : Node(K, V), height : Int32, *, last : Bool) : {K, V}
    if height == 0
      return remove_at(node, last ? node.len - 1 : 0)
    end
    parent = internal(node)
    i = last ? parent.len : 0
    entry = remove_edge(parent.edges[i], height - 1, last: last)
    rebalance(parent, i, height - 1)
    entry
  end

  private def remove_at(node : Node(K, V), i : Int32) : {K, V}
    entry = {node.keys[i], node.vals[i]}
    len = node.len - 1
    (node.keys + i).move_from(node.keys + i + 1, len - i)
    (node.vals + i).move_from(node.vals + i + 1, len - i)
    (node.keys + len).clear
    (node.vals + len).clear
    node.len = len
    entry
  end

  # Restores the minimum length of `parent.edges[i]` after a removal by
  # borrowing a key from a sibling or merging with one.
  private def rebalance(parent : Internal(K, V), i : Int32, child_height : Int32) : Nil
    return if parent.edges[i].len >= MIN_LEN
    if i > 0 && parent.edges[i - 1].len > MIN_LEN
      steal_left(parent, i, 1, child_height)
    elsif i < parent.len && parent.edges[i + 1].len > MIN_LEN
      steal_right(parent, i, child_height)
    elsif i > 0
      merge(parent, i - 1, child_height)
    else
      merge(parent, i, child_height)
    end
  end

  # :nodoc:
  #
  # Moves *count* keys from the end of `parent.edges[i - 1]` into the front
  # of `parent.edges[i]`, rotating through the parent's separating key.
  def self.steal_left(parent : Internal(K, V), i : Int32, count : Int32, child_height : Int32) : Nil
    left = parent.edges[i - 1]
    child = parent.edges[i]
    left_len = left.len
    child_len = child.len
    keep = left_len - count

    (child.keys + count).move_from(child.keys, child_len)
    (child.vals + count).move_from(child.vals, child_len)
    child.keys.copy_from(left.keys + keep + 1, count - 1)
    child.vals.copy_from(left.vals + keep + 1, count - 1)
    child.keys[count - 1] = parent.keys[i - 1]
    child.vals[count - 1] = parent.vals[i - 1]
    parent.keys[i - 1] = left.keys[keep]
    parent.vals[i - 1] = left.vals[keep]
    (left.keys + keep).clear(count)
    (left.vals + keep).clear(count)

    if child_height > 0
      left_edges = left.unsafe_as(Internal(K, V)).edges
      child_edges = child.unsafe_as(Internal(K, V)).edges
      (child_edges + count).move_from(child_edges, child_len + 1)
      child_edges.copy_from(left_edges + keep + 1, count)
      (left_edges + keep + 1).clear(count)
    end

    left.len = keep
    child.len = child_len + count
  end

  private def steal_left(parent : Internal(K, V), i : Int32, count : Int32, child_height : Int32) : Nil
    SortedMap(K, V).steal_left(parent, i, count, child_height)
  end

  # Moves the first key of `parent.edges[i + 1]` to the end of
  # `parent.edges[i]`, rotating through the parent's separating key.
  private def steal_right(parent : Internal(K, V), i : Int32, child_height : Int32) : Nil
    child = parent.edges[i]
    right = parent.edges[i + 1]
    child_len = child.len
    right_len = right.len

    child.keys[child_len] = parent.keys[i]
    child.vals[child_len] = parent.vals[i]
    parent.keys[i] = right.keys[0]
    parent.vals[i] = right.vals[0]
    right.keys.move_from(right.keys + 1, right_len - 1)
    right.vals.move_from(right.vals + 1, right_len - 1)
    (right.keys + right_len - 1).clear
    (right.vals + right_len - 1).clear

    if child_height > 0
      child_edges = internal(child).edges
      right_edges = internal(right).edges
      child_edges[child_len + 1] = right_edges[0]
      right_edges.move_from(right_edges + 1, right_len)
      (right_edges + right_len).clear
    end

    child.len = child_len + 1
    right.len = right_len - 1
  end

  # Merges `parent.edges[i + 1]` and the separating key `parent.keys[i]`
  # into `parent.edges[i]`.
  private def merge(parent : Internal(K, V), i : Int32, child_height : Int32) : Nil
    left = parent.edges[i]
    right = parent.edges[i + 1]
    left_len = left.len
    right_len = right.len

    left.keys[left_len] = parent.keys[i]
    left.vals[left_len] = parent.vals[i]
    (left.keys + left_len + 1).copy_from(right.keys, right_len)
    (left.vals + left_len + 1).copy_from(right.vals, right_len)
    if child_height > 0
      (internal(left).edges + left_len + 1).copy_from(internal(right).edges, right_len + 1)
    end
    left.len = left_len + 1 + right_len

    parent_len = parent.len - 1
    (parent.keys + i).move_from(parent.keys + i + 1, parent_len - i)
    (parent.vals + i).move_from(parent.vals + i + 1, parent_len - i)
    (parent.edges + i + 1).move_from(parent.edges + i + 2, parent_len - i)
    (parent.keys + parent_len).clear
    (parent.vals + parent_len).clear
    (parent.edges + parent_len + 1).clear
    parent.len = parent_len
  end

  # Returns the entry with the smallest key. Raises `Enumerable::EmptyError`
  # if the map is empty.
  def first : {K, V}
    first? || raise Enumerable::EmptyError.new
  end

  # Returns the entry with the smallest key, or `nil` if the map is empty.
  def first? : {K, V}?
    return nil if @size == 0
    node = @root
    @height.times { node = internal(node).edges[0] }
    {node.keys[0], node.vals[0]}
  end

  # Returns the entry with the largest key. Raises `Enumerable::EmptyError`
  # if the map is empty.
  def last : {K, V}
    last? || raise Enumerable::EmptyError.new
  end

  # Returns the entry with the largest key, or `nil` if the map is empty.
  def last? : {K, V}?
    return nil if @size == 0
    node = @root
    @height.times { node = internal(node).edges[node.len] }
    {node.keys[node.len - 1], node.vals[node.len - 1]}
  end

  # Returns the smallest key. Raises `Enumerable::EmptyError` if the map is
  # empty.
  def first_key : K
    first[0]
  end

  # Returns the smallest key, or `nil` if the map is empty.
  def first_key? : K?
    first?.try &.[0]
  end

  # Returns the largest key. Raises `Enumerable::EmptyError` if the map is
  # empty.
  def last_key : K
    last[0]
  end

  # Returns the largest key, or `nil` if the map is empty.
  def last_key? : K?
    last?.try &.[0]
  end

  # Removes and returns the entry with the smallest key. Raises
  # `Enumerable::EmptyError` if the map is empty.
  #
  # ```
  # map = SortedMap{2 => "b", 1 => "a"}
  # map.shift # => {1, "a"}
  # map.size  # => 1
  # ```
  def shift : {K, V}
    shift? || raise Enumerable::EmptyError.new
  end

  # Removes and returns the entry with the smallest key, or returns `nil` if
  # the map is empty.
  def shift? : {K, V}?
    take_edge(last: false)
  end

  # Removes and returns the entry with the largest key. Raises
  # `Enumerable::EmptyError` if the map is empty.
  def pop : {K, V}
    pop? || raise Enumerable::EmptyError.new
  end

  # Removes and returns the entry with the largest key, or returns `nil` if
  # the map is empty.
  def pop? : {K, V}?
    take_edge(last: true)
  end

  private def take_edge(*, last : Bool) : {K, V}?
    return nil if @size == 0
    entry = remove_edge(@root, @height, last: last)
    @size -= 1
    shrink_root
    entry
  end

  # Returns the entry with the largest key at or below *key*, or `nil` if
  # every key is larger.
  #
  # ```
  # map = SortedMap{10 => "a", 20 => "b"}
  # map.floor(15) # => {10, "a"}
  # map.floor(20) # => {20, "b"}
  # map.floor(5)  # => nil
  # ```
  def floor(key : K) : {K, V}?
    cursor = Cursor(K, V).new(@height)
    cursor.seek_le(@root, key, strict: false)
    cursor.entry?
  end

  # Returns the entry with the smallest key at or above *key*, or `nil` if
  # every key is smaller.
  #
  # ```
  # map = SortedMap{10 => "a", 20 => "b"}
  # map.ceiling(15) # => {20, "b"}
  # map.ceiling(10) # => {10, "a"}
  # map.ceiling(25) # => nil
  # ```
  def ceiling(key : K) : {K, V}?
    cursor = Cursor(K, V).new(@height)
    cursor.seek_ge(@root, key, strict: false)
    cursor.entry?
  end

  # Returns the entry with the largest key strictly below *key*, or `nil`
  # if there is none.
  #
  # ```
  # map = SortedMap{10 => "a", 20 => "b"}
  # map.lower(20) # => {10, "a"}
  # map.lower(10) # => nil
  # ```
  def lower(key : K) : {K, V}?
    cursor = Cursor(K, V).new(@height)
    cursor.seek_le(@root, key, strict: true)
    cursor.entry?
  end

  # Returns the entry with the smallest key strictly above *key*, or `nil`
  # if there is none.
  #
  # ```
  # map = SortedMap{10 => "a", 20 => "b"}
  # map.higher(10) # => {20, "b"}
  # map.higher(20) # => nil
  # ```
  def higher(key : K) : {K, V}?
    cursor = Cursor(K, V).new(@height)
    cursor.seek_ge(@root, key, strict: true)
    cursor.entry?
  end

  # Like `floor`, but returns only the key.
  def floor_key(key : K) : K?
    floor(key).try &.[0]
  end

  # Like `ceiling`, but returns only the key.
  def ceiling_key(key : K) : K?
    ceiling(key).try &.[0]
  end

  # Like `lower`, but returns only the key.
  def lower_key(key : K) : K?
    lower(key).try &.[0]
  end

  # Like `higher`, but returns only the key.
  def higher_key(key : K) : K?
    higher(key).try &.[0]
  end

  # Yields each entry in ascending key order.
  #
  # ```
  # map = SortedMap{2 => "b", 1 => "a"}
  # map.each { |key, value| puts "#{key}: #{value}" }
  # ```
  #
  # Output:
  #
  # ```text
  # 1: a
  # 2: b
  # ```
  def each(& : {K, V} ->) : Nil
    cursor = Cursor(K, V).new(@height)
    cursor.first(@root)
    while cursor.valid?
      yield cursor.entry
      cursor.next
    end
  end

  # Returns an iterator over the entries in ascending key order.
  def each : Iterator({K, V})
    cursor = Cursor(K, V).new(@height)
    cursor.first(@root)
    EntryIterator(K, V).new(cursor, reverse: false)
  end

  # Yields each entry whose key falls within *range*, in ascending key
  # order. Either end of the range may be `nil` for an open end.
  #
  # It starts at the first key in range in O(log n), so visiting k entries
  # costs O(log n + k).
  #
  # ```
  # map = SortedMap.new((1..10).map { |i| {i, i * i} })
  # map.each(3..5) { |key, value| puts "#{key}: #{value}" }
  # map.each(8..).map(&.[0]).to_a # => [8, 9, 10]
  # ```
  def each(range : Range, & : {K, V} ->) : Nil
    cursor = Cursor(K, V).new(@height)
    if start = range.begin
      cursor.seek_ge(@root, start, strict: false)
    else
      cursor.first(@root)
    end
    stop = range.end
    while cursor.valid?
      entry = cursor.entry
      unless stop.nil?
        c = cmp(entry[0], stop)
        break if c > 0 || (c == 0 && range.excludes_end?)
      end
      yield entry
      cursor.next
    end
  end

  # Returns an iterator over the entries whose keys fall within *range*, in
  # ascending key order.
  def each(range : Range) : Iterator({K, V})
    range_iterator(range, reverse: false)
  end

  # Yields each entry in descending key order.
  def reverse_each(& : {K, V} ->) : Nil
    cursor = Cursor(K, V).new(@height)
    cursor.last(@root)
    while cursor.valid?
      yield cursor.entry
      cursor.prev
    end
  end

  # Returns an iterator over the entries in descending key order.
  def reverse_each : Iterator({K, V})
    cursor = Cursor(K, V).new(@height)
    cursor.last(@root)
    EntryIterator(K, V).new(cursor, reverse: true)
  end

  # Yields each entry whose key falls within *range*, in descending key
  # order.
  #
  # ```
  # map = SortedMap.new((1..10).map { |i| {i, i * i} })
  # map.reverse_each(...4).map(&.[0]).to_a # => [3, 2, 1]
  # ```
  def reverse_each(range : Range, & : {K, V} ->) : Nil
    cursor = Cursor(K, V).new(@height)
    if stop = range.end
      cursor.seek_le(@root, stop, strict: range.excludes_end?)
    else
      cursor.last(@root)
    end
    start = range.begin
    while cursor.valid?
      entry = cursor.entry
      break if !start.nil? && cmp(entry[0], start) < 0
      yield entry
      cursor.prev
    end
  end

  # Returns an iterator over the entries whose keys fall within *range*, in
  # descending key order.
  def reverse_each(range : Range) : Iterator({K, V})
    range_iterator(range, reverse: true)
  end

  # Yields each key in ascending order.
  def each_key(& : K ->) : Nil
    each { |key, _| yield key }
  end

  # Returns an iterator over the keys in ascending order.
  def each_key : Iterator(K)
    each.map(&.[0])
  end

  # Yields each value in ascending key order.
  def each_value(& : V ->) : Nil
    each { |_, value| yield value }
  end

  # Returns an iterator over the values in ascending key order.
  def each_value : Iterator(V)
    each.map(&.[1])
  end

  # Returns the keys in ascending order.
  def keys : Array(K)
    keys = Array(K).new(@size)
    each_key { |key| keys << key }
    keys
  end

  # Returns the values in ascending key order.
  def values : Array(V)
    values = Array(V).new(@size)
    each_value { |value| values << value }
    values
  end

  # Returns the entries in ascending key order.
  def to_a : Array({K, V})
    entries = Array({K, V}).new(@size)
    each { |entry| entries << entry }
    entries
  end

  # Returns `true` if *other* has the same entries.
  def ==(other : SortedMap) : Bool
    return true if same?(other)
    return false unless size == other.size
    mine = each
    theirs = other.each
    while true
      a = mine.next
      b = theirs.next
      return true if a.is_a?(Iterator::Stop)
      return false if b.is_a?(Iterator::Stop)
      return false unless a == b
    end
  end

  # See `Object#hash(hasher)`
  def hash(hasher)
    hasher = @size.hash(hasher)
    each { |entry| hasher = entry.hash(hasher) }
    hasher
  end

  # Returns a copy of the map with the same keys and values (a shallow
  # copy). Changing either map afterwards leaves the other as is.
  def dup : self
    copy = SortedMap(K, V).new
    copy.replace_tree(copy_node(@root, @height), @height, @size)
    copy
  end

  # Returns a copy of the map whose keys and values are cloned too.
  def clone : self
    SortedMap(K, V).from_sorted(each.map { |key, value| {key.clone, value.clone} })
  end

  private def copy_node(node : Node(K, V), height : Int32) : Node(K, V)
    len = node.len
    if height == 0
      copy = Node(K, V).new
    else
      copy = parent = Internal(K, V).new
      edges = internal(node).edges
      (0..len).each { |i| parent.edges[i] = copy_node(edges[i], height - 1) }
    end
    copy.keys.copy_from(node.keys, len)
    copy.vals.copy_from(node.vals, len)
    copy.len = len
    copy
  end

  # :nodoc:
  def replace_tree(@root : Node(K, V), @height : Int32, @size : Int32) : self
    self
  end

  def to_s(io : IO) : Nil
    io << "SortedMap{"
    each_with_index do |(key, value), i|
      io << ", " if i > 0
      key.inspect(io)
      io << " => "
      value.inspect(io)
    end
    io << '}'
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end

  def pretty_print(pp) : Nil
    pp.list("SortedMap{", self, "}") do |(key, value)|
      pp.group do
        key.pretty_print(pp)
        pp.text " =>"
        pp.nest do
          pp.breakable
          value.pretty_print(pp)
        end
      end
    end
  end

  # :nodoc:
  #
  # Checks the tree's structural invariants and raises if one fails. Used
  # by the specs.
  def check_invariants : Nil
    count = check_node(@root, @height, nil, nil, root: true)
    raise "size #{@size} but #{count} keys" unless count == @size
  end

  private def check_node(node : Node(K, V), height : Int32, low : K?, high : K?, *, root : Bool) : Int32
    len = node.len
    raise "node with #{len} keys" if len > CAPACITY || (!root && len < MIN_LEN) || (root && height > 0 && len == 0)
    keys = node.keys
    (0...len).each do |i|
      raise "keys out of order" if i > 0 && cmp(keys[i - 1], keys[i]) >= 0
      raise "key below its subtree bound" if !low.nil? && cmp(keys[i], low) <= 0
      raise "key above its subtree bound" if !high.nil? && cmp(keys[i], high) >= 0
    end
    return len if height == 0
    edges = internal(node).edges
    count = len
    (0..len).each do |i|
      child_low = i == 0 ? low : keys[i - 1]
      child_high = i == len ? high : keys[i]
      count += check_node(edges[i], height - 1, child_low, child_high, root: false)
    end
    count
  end

  # :nodoc:
  #
  # A position in the tree: the path of nodes from the root down to the
  # entry, kept on the stack so seeking and stepping never allocate.
  #
  # Forward cursors (`first`, `seek_ge`, `next`) store for each level above
  # the entry the index of the edge they went down, which is also the index
  # of the next key at that level. Backward cursors (`last`, `seek_le`,
  # `prev`) store that index minus one, the next key going backward. A
  # cursor must only move in the direction it was positioned in.
  #
  # Every step checks lengths against the live nodes, so a cursor stays
  # memory safe when the map changes under it.
  struct Cursor(K, V)
    @nodes = uninitialized StaticArray(Node(K, V), 32)
    @index = uninitialized StaticArray(Int32, 32)
    @level = -1

    def initialize(@height : Int32)
    end

    @[AlwaysInline]
    def valid? : Bool
      @level >= 0
    end

    @[AlwaysInline]
    def entry : {K, V}
      node = @nodes.to_unsafe[@level]
      i = @index.to_unsafe[@level]
      {node.keys[i], node.vals[i]}
    end

    def entry? : {K, V}?
      entry if valid?
    end

    # Re-checks the position against the live nodes, which may have shrunk
    # since the cursor last moved.
    def revalidate(*, reverse : Bool) : Nil
      return unless valid?
      reverse ? ascend_backward : ascend_forward
    end

    @[AlwaysInline]
    private def internal(node : Node(K, V)) : Internal(K, V)
      node.unsafe_as(Internal(K, V))
    end

    def first(root : Node(K, V)) : Nil
      descend_first(root, 0)
    end

    def last(root : Node(K, V)) : Nil
      descend_last(root, 0)
    end

    # Positions at the first key at or above *key* (above, if *strict*).
    def seek_ge(root : Node(K, V), key : K, *, strict : Bool) : Nil
      node = root
      level = 0
      while true
        @nodes.to_unsafe[level] = node
        if strict
          i = SortedMap(K, V).upper_bound(node, key)
          found = false
        else
          i, found = SortedMap(K, V).search(node, key)
        end
        @index.to_unsafe[level] = i
        if found || level == @height
          @level = level
          ascend_forward unless found
          return
        end
        node = internal(node).edges[i]
        level += 1
      end
    end

    # Positions at the last key at or below *key* (below, if *strict*).
    def seek_le(root : Node(K, V), key : K, *, strict : Bool) : Nil
      node = root
      level = 0
      while true
        @nodes.to_unsafe[level] = node
        i, found = SortedMap(K, V).search(node, key)
        if found && !strict
          @index.to_unsafe[level] = i
          @level = level
          return
        end
        @index.to_unsafe[level] = i - 1
        if level == @height
          @level = level
          ascend_backward
          return
        end
        node = internal(node).edges[i]
        level += 1
      end
    end

    def next : Nil
      node = @nodes.to_unsafe[@level]
      i = @index.to_unsafe[@level] + 1
      @index.to_unsafe[@level] = i
      if @level < @height && i <= node.len
        descend_first(internal(node).edges[i], @level + 1)
      else
        ascend_forward
      end
    end

    def prev : Nil
      node = @nodes.to_unsafe[@level]
      i = @index.to_unsafe[@level]
      if @level < @height
        i = node.len if i > node.len
        @index.to_unsafe[@level] = i - 1
        descend_last(internal(node).edges[i], @level + 1)
      else
        i = node.len if i > node.len
        @index.to_unsafe[@level] = i - 1
        ascend_backward
      end
    end

    private def descend_first(node : Node(K, V), level : Int32) : Nil
      while true
        @nodes.to_unsafe[level] = node
        @index.to_unsafe[level] = 0
        break if level == @height
        node = internal(node).edges[0]
        level += 1
      end
      @level = level
      ascend_forward
    end

    private def descend_last(node : Node(K, V), level : Int32) : Nil
      while true
        len = node.len
        @nodes.to_unsafe[level] = node
        @index.to_unsafe[level] = len - 1
        break if level == @height
        node = internal(node).edges[len]
        level += 1
      end
      @level = level
      ascend_backward
    end

    private def ascend_forward : Nil
      level = @level
      while level >= 0 && @index.to_unsafe[level] >= @nodes.to_unsafe[level].len
        level -= 1
      end
      @level = level
    end

    private def ascend_backward : Nil
      level = @level
      while level >= 0 && @index.to_unsafe[level] < 0
        level -= 1
      end
      # A node may have shrunk under a backward cursor; clamp to its last key.
      if level >= 0
        len = @nodes.to_unsafe[level].len
        if @index.to_unsafe[level] >= len
          @index.to_unsafe[level] = len - 1
          @level = level
          ascend_backward
          return
        end
      end
      @level = level
    end
  end

  # :nodoc:
  class EntryIterator(K, V)
    include Iterator({K, V})

    @cursor : Cursor(K, V)
    @stop : K?
    @stop_set = false
    @exclusive = false

    # Iterates from *cursor* in the given direction, stopping past *stop*
    # when *stop_set* is true.
    def initialize(@cursor : Cursor(K, V), *, @reverse : Bool, @stop : K? = nil, @stop_set : Bool = false, @exclusive : Bool = false)
    end

    def next
      @cursor.revalidate(reverse: @reverse)
      return stop unless @cursor.valid?
      entry = @cursor.entry
      if @stop_set
        c = SortedMap(K, V).compare(entry[0], @stop.as(K))
        if @reverse ? c < 0 : (c > 0 || (c == 0 && @exclusive))
          @stop_set = false
          @cursor = Cursor(K, V).new(0)
          return stop
        end
      end
      @reverse ? @cursor.prev : @cursor.next
      entry
    end
  end

  private def range_iterator(range : Range, *, reverse : Bool) : EntryIterator(K, V)
    cursor = Cursor(K, V).new(@height)
    if reverse
      if (stop = range.end).nil?
        cursor.last(@root)
      else
        cursor.seek_le(@root, stop, strict: range.excludes_end?)
      end
      bound = range.begin
    else
      if (start = range.begin).nil?
        cursor.first(@root)
      else
        cursor.seek_ge(@root, start, strict: false)
      end
      bound = range.end
    end
    if bound.nil?
      EntryIterator(K, V).new(cursor, reverse: reverse)
    else
      EntryIterator(K, V).new(cursor, reverse: reverse, stop: bound, stop_set: true,
        exclusive: !reverse && range.excludes_end?)
    end
  end

  # :nodoc:
  #
  # Builds a tree from entries in ascending key order in O(n): it fills
  # nodes to capacity along the right spine, then tops up the nodes on the
  # right border, which may be short, from their left siblings.
  struct Builder(K, V)
    @spine : StaticArray(Node(K, V), 32)
    @height = 0
    @size = 0
    # Level of the node holding the last pushed key, or -1 before the first.
    @last_level = -1

    def initialize
      spine = uninitialized StaticArray(Node(K, V), 32)
      spine[0] = Node(K, V).new
      @spine = spine
    end

    def push(key : K, value : V, *, check : Bool) : Nil
      spine = @spine.to_unsafe
      if @last_level >= 0
        holder = spine[@last_level]
        c = SortedMap(K, V).compare(key, holder.keys[holder.len - 1])
        if c == 0
          holder.vals[holder.len - 1] = value
          return
        end
        raise ArgumentError.new("Keys are not in ascending order: #{key.inspect} after #{holder.keys[holder.len - 1].inspect}") if check && c < 0
      end

      leaf = spine[@height]
      if leaf.len < 11
        leaf.keys[leaf.len] = key
        leaf.vals[leaf.len] = value
        leaf.len += 1
        @last_level = @height
        @size += 1
        return
      end

      level = @height - 1
      while level >= 0 && spine[level].len >= 11
        level -= 1
      end
      if level < 0
        root = Internal(K, V).new
        root.edges[0] = spine[0]
        (spine + 1).move_from(spine, @height + 1)
        spine[0] = root
        @height += 1
        level = 0
      end

      parent = spine[level].unsafe_as(Internal(K, V))
      parent.keys[parent.len] = key
      parent.vals[parent.len] = value
      parent.len += 1

      child = Node(K, V).new
      spine[@height] = child
      (@height - 1).downto(level + 1) do |l|
        node = Internal(K, V).new
        node.edges[0] = child
        spine[l] = node
        child = node
      end
      parent.edges[parent.len] = child
      @last_level = level
      @size += 1
    end

    def build : SortedMap(K, V)
      spine = @spine.to_unsafe
      (0...@height).each do |level|
        parent = spine[level].unsafe_as(Internal(K, V))
        last = parent.len
        short = 5 - parent.edges[last].len
        SortedMap(K, V).steal_left(parent, last, short, @height - level - 1) if short > 0
      end
      SortedMap(K, V).new.replace_tree(spine[0], @height, @size)
    end
  end
end
