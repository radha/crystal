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
  # Deepest tree the cursors can walk: 2 * 6**31 keys, more than fit in
  # memory.
  private MAX_LEVELS = 32

  # :nodoc:
  #
  # A leaf node. Slots at or past `len` are cleared so that removed keys and
  # values are not kept alive by the GC.
  class Node(K, V)
    # Declared with explicit types so that `@len` sits right after the type
    # id, on the same cache line as the first keys.
    @len : Int32
    @keys : StaticArray(K, 11)
    @vals : StaticArray(V, 11)

    property len : Int32

    def initialize
      @len = 0
      @keys = uninitialized StaticArray(K, 11)
      @vals = uninitialized StaticArray(V, 11)
    end

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
    @edges : StaticArray(Node(K, V), 12)

    def initialize
      super
      @edges = uninitialized StaticArray(Node(K, V), 12)
    end

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
      middle = split_point(i)
      up_key, up_value = split_keys(node, right, middle)
      if i <= middle
        insert_at(node, i, key, value)
      else
        insert_at(right, i - middle - 1, key, value)
      end
      return {up_key, up_value, right}
    end

    parent = internal(node)
    split = insert(parent.edges[i], height - 1, key, value)
    return nil unless split
    insert_edge_or_split(parent, i, *split)
  end

  # Inserts *key* at index *i* of *parent* with *edge* as the child right
  # after it (or, with *edge_first*, right before it). When *parent* is
  # full it splits, and this returns the key and value that move up and
  # the new right sibling.
  private def insert_edge_or_split(parent : Internal(K, V), i : Int32, key : K, value : V, edge : Node(K, V), *, edge_first : Bool = false) : {K, V, Node(K, V)}?
    if parent.len < CAPACITY
      insert_edge_at(parent, i, key, value, edge, edge_first)
      return nil
    end
    right = Internal(K, V).new
    middle = split_point(i)
    up_key, up_value = split_keys(parent, right, middle)
    right.edges.copy_from(parent.edges + middle + 1, CAPACITY - middle)
    (parent.edges + middle + 1).clear(CAPACITY - middle)
    if i <= middle
      insert_edge_at(parent, i, key, value, edge, edge_first)
    else
      insert_edge_at(right, i - middle - 1, key, value, edge, edge_first)
    end
    {up_key, up_value, right}
  end

  # Index of the key that moves up when a full node splits to make room
  # at index *i*. As in Rust, the side that receives the new key ends up
  # with 5 or 6 keys and the other side with the rest, so appending in
  # order leaves nodes with 6 keys rather than 5.
  @[AlwaysInline]
  private def split_point(i : Int32) : Int32
    i < 5 ? 4 : (i <= 6 ? 5 : 6)
  end

  # Moves the keys after index *middle* of the full *node* into the empty
  # *right* and returns the key and value at *middle*, which leave *node*.
  private def split_keys(node : Node(K, V), right : Node(K, V), middle : Int32) : {K, V}
    right_len = CAPACITY - middle - 1
    right.keys.copy_from(node.keys + middle + 1, right_len)
    right.vals.copy_from(node.vals + middle + 1, right_len)
    right.len = right_len
    key = node.keys[middle]
    value = node.vals[middle]
    (node.keys + middle).clear(CAPACITY - middle)
    (node.vals + middle).clear(CAPACITY - middle)
    node.len = middle
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
  # after it, or right before it if *edge_first*.
  private def insert_edge_at(node : Internal(K, V), i : Int32, key : K, value : V, edge : Node(K, V), edge_first : Bool = false) : Nil
    edges = node.edges
    (edges + i + 2).move_from(edges + i + 1, node.len - i)
    if edge_first
      edges[i + 1] = edges[i]
      edges[i] = edge
    else
      edges[i + 1] = edge
    end
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
  #
  # A range of more than a few keys is removed by cutting the tree at both
  # ends of the range and joining the outer parts, in O(log n) plus a count
  # of the removed nodes, rather than deleting keys one by one.
  def delete_range(range : Range) : Int32
    return 0 if @size == 0

    doomed = Array(K).new(SMALL_RANGE + 1)
    each(range) do |key, _|
      doomed << key
      break if doomed.size > SMALL_RANGE
    end
    if doomed.size <= SMALL_RANGE
      doomed.each { |key| delete(key) }
      return doomed.size
    end

    height = @height
    if (start = range.begin).nil?
      left_root, left_height = Node(K, V).new, 0
      rest = @root
    else
      left_root, rest = split_node(@root, height, start, inclusive: false)
      left_root, left_height = fix_right_border(left_root, height)
    end

    if (stop = range.end).nil?
      middle = rest
      right_root, right_height = Node(K, V).new, 0
    else
      middle, right_root = split_node(rest, height, stop, inclusive: !range.excludes_end?)
      right_root, right_height = fix_left_border(right_root, height)
    end

    removed = count_keys(middle, height)
    size = @size - removed
    join(left_root, left_height, right_root, right_height)
    @size = size
    removed
  end

  # Ranges this small are deleted key by key.
  private SMALL_RANGE = 32

  # Cuts the subtree under *node* in two: keys below *key* (or at or below
  # it, if *inclusive*) stay in *node*, and the rest move to a new node of
  # the same height. Nodes along the cut may be left short, or even empty;
  # `fix_right_border` and `fix_left_border` repair them.
  private def split_node(node : Node(K, V), height : Int32, key : K, *, inclusive : Bool) : {Node(K, V), Node(K, V)}
    i = inclusive ? SortedMap(K, V).upper_bound(node, key) : search(node, key)[0]
    moved = node.len - i
    right = height == 0 ? Node(K, V).new : Internal(K, V).new
    right.keys.copy_from(node.keys + i, moved)
    right.vals.copy_from(node.vals + i, moved)
    right.len = moved
    (node.keys + i).clear(moved)
    (node.vals + i).clear(moved)
    node.len = i
    if height > 0
      edges = internal(node).edges
      right_edges = internal(right).edges
      left_part, right_part = split_node(edges[i], height - 1, key, inclusive: inclusive)
      edges[i] = left_part
      right_edges[0] = right_part
      (right_edges + 1).copy_from(edges + i + 1, moved)
      (edges + i + 1).clear(moved)
    end
    {node, right}
  end

  # Repairs the right border of a tree left short by `split_node` and
  # returns its root and height. Going down the border, each short node is
  # topped up from its left sibling or merged with it. An internal node is
  # topped up to one above the minimum, because merging its own children
  # next may take one key away.
  private def fix_right_border(root : Node(K, V), height : Int32) : {Node(K, V), Int32}
    root, height = collapse_root(root, height)
    node = root
    level = height
    while level > 0
      parent = internal(node)
      last = parent.len
      child = parent.edges[last]
      target = level > 1 ? MIN_LEN + 1 : MIN_LEN
      if child.len < target
        if parent.edges[last - 1].len + child.len >= target + MIN_LEN
          steal_left(parent, last, target - child.len, level - 1)
        else
          merge(parent, last - 1, level - 1)
        end
      end
      node = parent.edges[parent.len]
      level -= 1
    end
    collapse_root(root, height)
  end

  # Mirror of `fix_right_border` for the left border.
  private def fix_left_border(root : Node(K, V), height : Int32) : {Node(K, V), Int32}
    root, height = collapse_root(root, height)
    node = root
    level = height
    while level > 0
      parent = internal(node)
      child = parent.edges[0]
      target = level > 1 ? MIN_LEN + 1 : MIN_LEN
      if child.len < target
        if parent.edges[1].len + child.len >= target + MIN_LEN
          steal_right(parent, 0, target - child.len, level - 1)
        else
          merge(parent, 0, level - 1)
        end
      end
      node = parent.edges[0]
      level -= 1
    end
    collapse_root(root, height)
  end

  # Drops empty internal roots.
  private def collapse_root(root : Node(K, V), height : Int32) : {Node(K, V), Int32}
    while height > 0 && root.len == 0
      root = internal(root).edges[0]
      height -= 1
    end
    {root, height}
  end

  private def count_keys(node : Node(K, V), height : Int32) : Int32
    count = node.len
    if height > 0
      edges = internal(node).edges
      (0..node.len).each { |i| count += count_keys(edges[i], height - 1) }
    end
    count
  end

  # Makes this map the concatenation of two valid trees whose keys are all
  # smaller in the first. The size is left for the caller to set.
  private def join(left : Node(K, V), left_height : Int32, right : Node(K, V), right_height : Int32) : Nil
    @root, @height = left, left_height
    return if right.len == 0
    if left.len == 0
      @root, @height = right, right_height
      return
    end

    # The largest key on the left becomes the separator between the two.
    sep_key, sep_value = remove_edge(@root, @height, last: true)
    shrink_root
    if @root.len == 0
      @root, @height = right, right_height
      self[sep_key] = sep_value
      return
    end
    left, left_height = @root, @height

    if left_height == right_height
      if left.len + 1 + right.len <= CAPACITY
        SortedMap(K, V).concat(left, sep_key, sep_value, right, left_height)
        return
      end
      if left.len < MIN_LEN
        sep_key, sep_value = SortedMap(K, V).shift_left(left, right, MIN_LEN - left.len, left_height, sep_key, sep_value)
      elsif right.len < MIN_LEN
        sep_key, sep_value = SortedMap(K, V).shift_right(left, right, MIN_LEN - right.len, left_height, sep_key, sep_value)
      end
      grow_root(sep_key, sep_value, right)
    elsif left_height > right_height
      if split = append_right(left, left_height, right, right_height, sep_key, sep_value)
        grow_root(*split)
      end
    else
      @root, @height = right, right_height
      if split = append_left(right, right_height, left, left_height, sep_key, sep_value)
        grow_root(*split)
      end
    end
  end

  # Hangs the shorter tree *right* off the right spine of the subtree under
  # *node*, with the separator between them. Returns a split like `insert`.
  private def append_right(node : Node(K, V), height : Int32, right : Node(K, V), right_height : Int32, sep_key : K, sep_value : V) : {K, V, Node(K, V)}?
    parent = internal(node)
    last = parent.len
    if height - 1 > right_height
      split = append_right(parent.edges[last], height - 1, right, right_height, sep_key, sep_value)
      return split && insert_edge_or_split(parent, last, *split)
    end

    sibling = parent.edges[last]
    if sibling.len + 1 + right.len <= CAPACITY
      SortedMap(K, V).concat(sibling, sep_key, sep_value, right, right_height)
      return nil
    end
    if right.len < MIN_LEN
      sep_key, sep_value = SortedMap(K, V).shift_right(sibling, right, MIN_LEN - right.len, right_height, sep_key, sep_value)
    end
    insert_edge_or_split(parent, last, sep_key, sep_value, right)
  end

  # Mirror of `append_right`: hangs the shorter tree *left* off the left
  # spine of the subtree under *node*.
  private def append_left(node : Node(K, V), height : Int32, left : Node(K, V), left_height : Int32, sep_key : K, sep_value : V) : {K, V, Node(K, V)}?
    parent = internal(node)
    if height - 1 > left_height
      split = append_left(parent.edges[0], height - 1, left, left_height, sep_key, sep_value)
      return split && insert_edge_or_split(parent, 0, *split)
    end

    sibling = parent.edges[0]
    if left.len + 1 + sibling.len <= CAPACITY
      SortedMap(K, V).concat(left, sep_key, sep_value, sibling, left_height)
      parent.edges[0] = left
      return nil
    end
    if left.len < MIN_LEN
      sep_key, sep_value = SortedMap(K, V).shift_left(left, sibling, MIN_LEN - left.len, left_height, sep_key, sep_value)
    end
    insert_edge_or_split(parent, 0, sep_key, sep_value, left, edge_first: true)
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
      steal_right(parent, i, 1, child_height)
    elsif i > 0
      merge(parent, i - 1, child_height)
    else
      merge(parent, i, child_height)
    end
  end

  # :nodoc:
  #
  # Moves *count* keys from the end of *left* into the front of *right*,
  # rotating through the separator *sep_key* between them, and returns the
  # new separator. The two nodes sit *height* levels above the leaves.
  def self.shift_right(left : Node(K, V), right : Node(K, V), count : Int32, height : Int32, sep_key : K, sep_value : V) : {K, V}
    left_len = left.len
    right_len = right.len
    keep = left_len - count

    (right.keys + count).move_from(right.keys, right_len)
    (right.vals + count).move_from(right.vals, right_len)
    right.keys.copy_from(left.keys + keep + 1, count - 1)
    right.vals.copy_from(left.vals + keep + 1, count - 1)
    right.keys[count - 1] = sep_key
    right.vals[count - 1] = sep_value
    separator = {left.keys[keep], left.vals[keep]}
    (left.keys + keep).clear(count)
    (left.vals + keep).clear(count)

    if height > 0
      left_edges = left.unsafe_as(Internal(K, V)).edges
      right_edges = right.unsafe_as(Internal(K, V)).edges
      (right_edges + count).move_from(right_edges, right_len + 1)
      right_edges.copy_from(left_edges + keep + 1, count)
      (left_edges + keep + 1).clear(count)
    end

    left.len = keep
    right.len = right_len + count
    separator
  end

  # :nodoc:
  #
  # Moves *count* keys from the front of *right* to the end of *left*,
  # rotating through the separator between them, and returns the new
  # separator.
  def self.shift_left(left : Node(K, V), right : Node(K, V), count : Int32, height : Int32, sep_key : K, sep_value : V) : {K, V}
    left_len = left.len
    right_len = right.len
    rest = right_len - count

    left.keys[left_len] = sep_key
    left.vals[left_len] = sep_value
    (left.keys + left_len + 1).copy_from(right.keys, count - 1)
    (left.vals + left_len + 1).copy_from(right.vals, count - 1)
    separator = {right.keys[count - 1], right.vals[count - 1]}
    right.keys.move_from(right.keys + count, rest)
    right.vals.move_from(right.vals + count, rest)
    (right.keys + rest).clear(count)
    (right.vals + rest).clear(count)

    if height > 0
      left_edges = left.unsafe_as(Internal(K, V)).edges
      right_edges = right.unsafe_as(Internal(K, V)).edges
      (left_edges + left_len + 1).copy_from(right_edges, count)
      right_edges.move_from(right_edges + count, rest + 1)
      (right_edges + rest + 1).clear(count)
    end

    left.len = left_len + count
    right.len = rest
    separator
  end

  # :nodoc:
  #
  # Appends the separator and every key (and edge) of *right* to *left*.
  # The caller makes sure they fit.
  def self.concat(left : Node(K, V), sep_key : K, sep_value : V, right : Node(K, V), height : Int32) : Nil
    left_len = left.len
    right_len = right.len
    left.keys[left_len] = sep_key
    left.vals[left_len] = sep_value
    (left.keys + left_len + 1).copy_from(right.keys, right_len)
    (left.vals + left_len + 1).copy_from(right.vals, right_len)
    if height > 0
      (left.unsafe_as(Internal(K, V)).edges + left_len + 1).copy_from(right.unsafe_as(Internal(K, V)).edges, right_len + 1)
    end
    left.len = left_len + 1 + right_len
  end

  # :nodoc:
  #
  # Moves *count* keys from `parent.edges[i - 1]` into `parent.edges[i]`
  # through the parent's separating key.
  def self.steal_left(parent : Internal(K, V), i : Int32, count : Int32, child_height : Int32) : Nil
    sep = shift_right(parent.edges[i - 1], parent.edges[i], count, child_height, parent.keys[i - 1], parent.vals[i - 1])
    parent.keys[i - 1], parent.vals[i - 1] = sep
  end

  # :nodoc:
  #
  # Moves *count* keys from `parent.edges[i + 1]` into `parent.edges[i]`
  # through the parent's separating key.
  def self.steal_right(parent : Internal(K, V), i : Int32, count : Int32, child_height : Int32) : Nil
    sep = shift_left(parent.edges[i], parent.edges[i + 1], count, child_height, parent.keys[i], parent.vals[i])
    parent.keys[i], parent.vals[i] = sep
  end

  # :nodoc:
  #
  # Merges `parent.edges[i + 1]` and the separating key `parent.keys[i]`
  # into `parent.edges[i]`.
  def self.merge(parent : Internal(K, V), i : Int32, child_height : Int32) : Nil
    concat(parent.edges[i], parent.keys[i], parent.vals[i], parent.edges[i + 1], child_height)
    parent_len = parent.len - 1
    (parent.keys + i).move_from(parent.keys + i + 1, parent_len - i)
    (parent.vals + i).move_from(parent.vals + i + 1, parent_len - i)
    (parent.edges + i + 1).move_from(parent.edges + i + 2, parent_len - i)
    (parent.keys + parent_len).clear
    (parent.vals + parent_len).clear
    (parent.edges + parent_len + 1).clear
    parent.len = parent_len
  end

  private def steal_left(parent : Internal(K, V), i : Int32, count : Int32, child_height : Int32) : Nil
    SortedMap(K, V).steal_left(parent, i, count, child_height)
  end

  private def steal_right(parent : Internal(K, V), i : Int32, count : Int32, child_height : Int32) : Nil
    SortedMap(K, V).steal_right(parent, i, count, child_height)
  end

  private def merge(parent : Internal(K, V), i : Int32, child_height : Int32) : Nil
    SortedMap(K, V).merge(parent, i, child_height)
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
    closest(key, below: true, strict: false)
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
    closest(key, below: false, strict: false)
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
    closest(key, below: true, strict: true)
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
    closest(key, below: false, strict: true)
  end

  # Finds the closest key below (or above) *key* in one descent, keeping the
  # best candidate seen on the way down. An equal key is the answer unless
  # *strict*.
  private def closest(key : K, *, below : Bool, strict : Bool) : {K, V}?
    node = @root
    height = @height
    best = nil
    best_index = 0
    while true
      i, found = search(node, key)
      if found
        return {node.keys[i], node.vals[i]} unless strict
        # Everything under edges[i] is below key and everything under
        # edges[i + 1] above it.
        i += 1 unless below
      end
      if below
        if i > 0
          best = node
          best_index = i - 1
        end
      elsif i < node.len
        best = node
        best_index = i
      end
      break if height == 0
      node = internal(node).edges[i]
      height -= 1
    end
    {best.keys[best_index], best.vals[best_index]} if best
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
    cursor.each_forward { |entry| yield entry }
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
    if stop.nil?
      cursor.each_forward { |entry| yield entry }
    else
      exclusive = range.excludes_end?
      cursor.each_forward do |entry|
        c = cmp(entry[0], stop)
        break if c > 0 || (c == 0 && exclusive)
        yield entry
      end
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
    cursor.each_backward { |entry| yield entry }
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
    if start.nil?
      cursor.each_backward { |entry| yield entry }
    else
      cursor.each_backward do |entry|
        break if cmp(entry[0], start) < 0
        yield entry
      end
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

    # Yields every entry from the current position onward. Within a leaf it
    # loops over the keys directly, re-reading the length each time in case
    # the block changes the map.
    def each_forward(&) : Nil
      while @level >= 0
        node = @nodes.to_unsafe[@level]
        i = @index.to_unsafe[@level]
        if @level == @height
          while i < node.len
            yield({node.keys[i], node.vals[i]})
            i += 1
          end
          @index.to_unsafe[@level] = i
          ascend_forward
        else
          yield({node.keys[i], node.vals[i]})
          self.next
        end
      end
    end

    # Yields every entry from the current position backward.
    def each_backward(&) : Nil
      while @level >= 0
        node = @nodes.to_unsafe[@level]
        i = @index.to_unsafe[@level]
        if @level == @height
          while i >= 0
            i = node.len - 1 if i >= node.len
            break if i < 0
            yield({node.keys[i], node.vals[i]})
            i -= 1
          end
          @index.to_unsafe[@level] = -1
          ascend_backward
        else
          yield({node.keys[i], node.vals[i]})
          prev
        end
      end
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
