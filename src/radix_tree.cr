# A `RadixTree` is a dictionary from byte-string keys to values, stored in a
# compressed [radix tree](https://en.wikipedia.org/wiki/Radix_tree) (a
# PATRICIA trie): each edge carries a run of key bytes, and nodes with a
# single child and no value are merged into their child.
#
# Besides exact lookups, a `RadixTree` answers prefix questions quickly:
# the longest stored key that is a prefix of a probe (`longest_prefix`, as
# in a URL router or an IP routing table), every stored key that is a
# prefix of a probe (`each_prefix`), and every stored key that starts with
# a prefix (`each_with_prefix`, as in autocompletion). Each of these walks
# one path of the tree, so its cost depends on the length of the probe,
# not on the number of keys.
#
# ```
# require "radix_tree"
#
# routes = RadixTree(Symbol).new
# routes["/"] = :root
# routes["/users"] = :users
# routes["/users/admin"] = :admin
#
# routes["/users"]                         # => :users
# routes.longest_prefix("/users/42/posts") # => {"/users", :users}
# routes.longest_prefix_value("/about")    # => :root
# routes.with_prefix("/users").to_a        # => [{"/users", :users}, {"/users/admin", :admin}]
# routes.keys                              # => ["/", "/users", "/users/admin"]
# ```
#
# Keys are sequences of bytes. Every method that takes a key accepts either
# a `String` or `Bytes`, and the two are interchangeable: `"abc"` and
# `"abc".to_slice` name the same key. Keys are yielded and returned as
# `String`s; a key stored from `Bytes` that is not valid UTF-8 comes back
# as a `String` holding those same bytes. Iteration visits keys in
# byte-wise lexicographic order, so a key comes before every key that
# extends it.
#
# The tree keeps a reference to each `String` key it stores (strings are
# immutable), and copies each `Bytes` key once into a new `String`, so
# changing the slice afterwards does not affect the tree. Lookups do not
# allocate. `longest_prefix` and the iteration methods return the stored key
# strings, so they do not allocate per key either.
#
# Adding or removing keys while iterating the tree is memory safe, but the
# iteration may then skip or repeat keys.
#
# NOTE: To use `RadixTree`, you must explicitly import it with `require "radix_tree"`
class RadixTree(V)
  include Enumerable({String, V})
  include Iterable({String, V})

  # :nodoc:
  #
  # A node of the tree. Nodes are stored by value in their parent's edge
  # block (the root in the tree itself), so descending one level reads one
  # block. Leaves own no block.
  #
  # The label is the run of key bytes on the edge from the parent; its
  # first byte is the one the parent files the node under. Labels point
  # into stored key strings, at the offset where the node starts, so the
  # bytes before a label spell the node's whole path.
  #
  # A node holds a value exactly when `key` is set. Every node other than
  # the root has a non-empty label, and every node other than the root that
  # holds no value has at least two children.
  #
  # Being a struct, a node read through a pointer is a copy: mutate a copy
  # and write it back.
  struct Node(V)
    # Nodes with at most this many child slots keep their children's first
    # bytes in `@small`, so finding a child reads no other memory.
    INLINE = 16

    @label : Pointer(UInt8)
    @label_size : Int32
    @count : UInt16
    @capacity : UInt16
    # The children's first bytes, in order, while `@capacity <= INLINE`
    # (byte `i` of the array).
    @small : StaticArray(UInt64, 2)
    # Children in ascending order of first byte. Past `INLINE` slots, their
    # first bytes sit just before them in the same block, padded to a
    # multiple of 8.
    @edges : Pointer(Node(V))
    @key : String?
    @value : V

    getter label : Pointer(UInt8)
    getter label_size : Int32
    getter edges : Pointer(Node(V))
    getter key : String?

    def initialize(@label : Pointer(UInt8), @label_size : Int32)
      @count = 0_u16
      @capacity = 0_u16
      @small = StaticArray(UInt64, 2).new(0_u64)
      @edges = Pointer(Node(V)).null
      @key = nil
      @value = uninitialized V
      pointerof(@value).clear
    end

    def initialize(@label : Pointer(UInt8), @label_size : Int32, @key : String, @value : V)
      @count = 0_u16
      @capacity = 0_u16
      @small = StaticArray(UInt64, 2).new(0_u64)
      @edges = Pointer(Node(V)).null
    end

    def count : Int32
      @count.to_i32
    end

    def value : V
      @value
    end

    def value=(@value : V) : V
    end

    def stored_key : String
      @key.not_nil!
    end

    def set(key : String, value : V) : Nil
      @key = key
      @value = value
    end

    def unset : Nil
      @key = nil
      pointerof(@value).clear
    end

    def relabel(@label : Pointer(UInt8), @label_size : Int32) : Nil
    end

    # May point into this node itself: call it on a variable, not on a
    # temporary such as `ptr.value`, if the pointer outlives the call.
    def first_bytes : Pointer(UInt8)
      if @capacity <= INLINE
        pointerof(@small).as(Pointer(UInt8))
      else
        @edges.as(Pointer(UInt8)) - Node.byte_area(@capacity.to_i32)
      end
    end

    protected def self.byte_area(capacity : Int32) : Int32
      capacity <= INLINE ? 0 : (capacity + 7) & ~7
    end

    # Returns the position of the child filed under *byte*, or -1.
    @[AlwaysInline]
    def index(byte : UInt8) : Int32
      count = @count.to_i32
      if @capacity <= INLINE
        # Find a byte of `@small` equal to *byte* with word operations: the
        # lowest byte flagged in `found` is the first zero byte of `x`.
        # Bytes past `count` may hold stale values and are rejected below.
        # Assumes a little-endian target, as all of Crystal's are.
        pattern = byte.to_u64 &* 0x0101010101010101_u64
        words = pointerof(@small).as(Pointer(UInt64))
        i = Node.find_byte(words[0] ^ pattern)
        if i < 0 && count > 8
          i = Node.find_byte(words[1] ^ pattern)
          i += 8 if i >= 0
        end
        return i < count ? i : -1
      end
      bytes = first_bytes
      i = 0
      while i < count
        b = bytes[i]
        return i if b == byte
        break if b > byte
        i += 1
      end
      -1
    end

    # Returns the position of the first zero byte of *x*, or -1.
    @[AlwaysInline]
    protected def self.find_byte(x : UInt64) : Int32
      found = (x &- 0x0101010101010101_u64) & ~x & 0x8080808080808080_u64
      found == 0 ? -1 : found.trailing_zeros_count.to_i32 // 8
    end

    # Returns a pointer to the child filed under *byte*, or a null pointer.
    @[AlwaysInline]
    def child(byte : UInt8) : Pointer(Node(V))
      i = index(byte)
      i >= 0 ? @edges + i : Pointer(Node(V)).null
    end

    # Returns the position of the first child whose first byte is not less
    # than *byte*.
    def lower_bound(byte : UInt8) : Int32
      bytes = first_bytes
      count = @count.to_i32
      i = 0
      while i < count && bytes[i] < byte
        i += 1
      end
      i
    end

    def insert_edge(i : Int32, byte : UInt8, child : Node(V)) : Nil
      count = @count.to_i32
      if count == @capacity
        grow(count == 0 ? 2 : count * 2)
      end
      bytes = first_bytes
      tail = count - i
      if tail > 0
        (@edges + i + 1).move_from(@edges + i, tail)
        (bytes + i + 1).move_from(bytes + i, tail)
      end
      @edges[i] = child
      bytes[i] = byte
      @count += 1
    end

    def remove_edge(i : Int32) : Nil
      count = @count.to_i32 - 1
      if count == 0
        @edges = Pointer(Node(V)).null
        @capacity = 0_u16
        @count = 0_u16
        @small = StaticArray(UInt64, 2).new(0_u64)
        return
      end
      bytes = first_bytes
      tail = count - i
      if tail > 0
        (@edges + i).move_from(@edges + i + 1, tail)
        (bytes + i).move_from(bytes + i + 1, tail)
      end
      # Let the GC reclaim what the vacated slot referenced.
      (@edges + count).clear
      @count = count.to_u16
    end

    private def grow(capacity : Int32) : Nil
      count = @count.to_i32
      area = Node.byte_area(capacity)
      slots = capacity + (area + sizeof(Node(V)) - 1) // sizeof(Node(V))
      block = Pointer(Node(V)).malloc(slots).as(Pointer(UInt8))
      edges = (block + (slots - capacity) * sizeof(Node(V))).as(Pointer(Node(V)))
      if count > 0
        edges.copy_from(@edges, count)
        if area > 0
          (edges.as(Pointer(UInt8)) - area).copy_from(first_bytes, count)
        end
      end
      @edges = edges
      @capacity = capacity.to_u16
    end

    # Returns a copy of this node with copies of its descendants. Labels
    # and keys are shared.
    def deep_copy : Node(V)
      copy = self
      copy.copy_edges
      copy
    end

    protected def copy_edges : Nil
      count = @count.to_i32
      return if count == 0
      bytes = Bytes.new(first_bytes, count).dup
      edges = @edges
      @count = 0_u16
      @capacity = 0_u16
      @small = StaticArray(UInt64, 2).new(0_u64)
      @edges = Pointer(Node(V)).null
      count.times do |i|
        insert_edge(i, bytes[i], edges[i].deep_copy)
      end
    end

    # Returns the key of some node at or below this one that holds a value.
    def some_key : String
      node = self
      while true
        if key = node.key
          return key
        end
        node = node.edges.value
      end
    end
  end

  # :nodoc:
  #
  # Depth-first pre-order traversal, which visits the nodes that hold a
  # value in byte-wise key order. It scans the children of one node at a
  # time (`@node`, from position `@index`), and keeps the nodes above it,
  # with the position to resume at, on an explicit stack.
  #
  # If the tree changes during the walk, the cached `@edges` and `@count`
  # may describe an older block; the GC keeps that block alive, so reading
  # it stays memory safe.
  struct Walker(V)
    @node : Pointer(Node(V))
    @edges : Pointer(Node(V))
    @count : Int32
    @index : Int32
    @start : Pointer(Node(V))
    @stack : Pointer(Pointer(Node(V)))
    @indices : Pointer(Int32)
    @depth : Int32
    @capacity : Int32

    def initialize(start : Pointer(Node(V)))
      @node = start
      @start = start
      @edges = Pointer(Node(V)).null
      @count = 0
      @index = 0
      @stack = Pointer(Pointer(Node(V))).null
      @indices = Pointer(Int32).null
      @depth = 0
      @capacity = 0
    end

    # Returns the next node that holds a value, or a null pointer at the
    # end.
    def next_node : Pointer(Node(V))
      unless @start.null?
        # First call: visit the start node itself.
        start = @start
        @start = Pointer(Node(V)).null
        node = start.value
        @edges = node.edges
        @count = node.count
        return start if node.key
      end
      while true
        while @index < @count
          child = @edges + @index
          @index += 1
          node = child.value
          if node.count == 0
            return child if node.key
          else
            # Descend into the child, saving our place.
            push(@node, @index)
            @node = child
            @edges = node.edges
            @count = node.count
            @index = 0
            return child if node.key
          end
        end
        return Pointer(Node(V)).null if @depth == 0
        @depth -= 1
        @node = @stack[@depth]
        @index = @indices[@depth]
        node = @node.value
        @edges = node.edges
        @count = node.count
      end
    end

    private def push(node : Pointer(Node(V)), index : Int32) : Nil
      if @depth == @capacity
        @capacity = @capacity == 0 ? 16 : @capacity * 2
        @stack = @stack.realloc(@capacity)
        @indices = @indices.realloc(@capacity)
      end
      @stack[@depth] = node
      @indices[@depth] = index
      @depth += 1
    end
  end

  @root : Node(V)
  @size : Int32

  # Creates an empty tree.
  #
  # ```
  # tree = RadixTree(Int32).new
  # tree.empty? # => true
  # ```
  def initialize
    @root = Node(V).new(Pointer(UInt8).null, 0)
    @size = 0
  end

  # Creates a tree holding the given key-value pairs. Keys may be `String`s
  # or `Bytes`. A later pair overwrites an earlier one with the same key.
  #
  # ```
  # tree = RadixTree.new({"b" => 2, "a" => 1})
  # tree.to_a # => [{"a", 1}, {"b", 2}]
  # ```
  def self.new(entries : Enumerable({String, V}))
    tree = RadixTree(V).new
    entries.each { |key, value| tree[key] = value }
    tree
  end

  # :ditto:
  def self.new(entries : Enumerable({Bytes, V}))
    tree = RadixTree(V).new
    entries.each { |key, value| tree[key] = value }
    tree
  end

  # Returns the number of keys in the tree.
  def size : Int32
    @size
  end

  # Returns `true` if the tree holds no keys.
  def empty? : Bool
    @size == 0
  end

  # Removes every key from the tree.
  def clear : self
    @root = Node(V).new(Pointer(UInt8).null, 0)
    @size = 0
    self
  end

  private def root : Pointer(Node(V))
    pointerof(@root)
  end

  # Returns the node holding exactly *key*, or a null pointer.
  #
  # The descent only looks at the byte that picks each child and skips the
  # rest of its label, then compares the whole key once against the key
  # stored at the node it ends on (as in a PATRICIA trie). This reads one
  # key string instead of one label per level, which saves a cache miss per
  # level on large trees.
  private def find_node(ptr : Pointer(UInt8), len : Int32) : Pointer(Node(V))
    node = root
    pos = 0
    while pos < len
      node = node.value.child(ptr[pos])
      return node if node.null?
      pos += node.value.label_size
    end
    if pos == len && (key = node.value.key) && key.to_unsafe.memcmp(ptr, len) == 0
      node
    else
      Pointer(Node(V)).null
    end
  end

  # Returns how many leading bytes of *a* and *b* agree, up to *size*.
  private def common_prefix(a : Pointer(UInt8), b : Pointer(UInt8), size : Int32) : Int32
    i = 0
    while i < size && a[i] == b[i]
      i += 1
    end
    i
  end

  # Returns the value for *key*, or `nil` if the tree does not hold it.
  #
  # ```
  # tree = RadixTree(Int32){"a" => 1}
  # tree["a"]? # => 1
  # tree["b"]? # => nil
  # ```
  def []?(key : String | Bytes) : V?
    node = find_node(key.to_unsafe, key.bytesize)
    node.value.value unless node.null?
  end

  # Returns the value for *key*, or raises `KeyError` if the tree does not
  # hold it.
  #
  # ```
  # tree = RadixTree(Int32){"a" => 1}
  # tree["a"] # => 1
  # tree["b"] # raises KeyError
  # ```
  def [](key : String | Bytes) : V
    fetch(key) { raise KeyError.new("Missing radix tree key: #{key_string(key).inspect}") }
  end

  # Returns the value for *key*, or the block's result (given *key*) if the
  # tree does not hold it.
  #
  # ```
  # tree = RadixTree(Int32){"a" => 1}
  # tree.fetch("b") { |key| key.size } # => 1
  # ```
  def fetch(key : String | Bytes, &)
    node = find_node(key.to_unsafe, key.bytesize)
    node.null? ? yield(key) : node.value.value
  end

  # Returns the value for *key*, or *default* if the tree does not hold it.
  def fetch(key : String | Bytes, default)
    fetch(key) { default }
  end

  # Returns `true` if the tree holds *key*.
  def has_key?(key : String | Bytes) : Bool
    !find_node(key.to_unsafe, key.bytesize).null?
  end

  # Returns `true` if the tree holds some key that starts with *prefix*.
  # Every key starts with the empty prefix.
  def has_prefix?(prefix : String | Bytes) : Bool
    !subtree(prefix.to_unsafe, prefix.bytesize).null?
  end

  # Returns `true` if some key maps to *value*.
  def has_value?(value) : Bool
    each_value { |v| return true if v == value }
    false
  end

  # Stores *value* under *key*, replacing any value already there, and
  # returns *value*.
  #
  # ```
  # tree = RadixTree(Int32).new
  # tree["abc"] = 1
  # tree["abd".to_slice] = 2
  # tree.keys # => ["abc", "abd"]
  # ```
  def []=(key : String | Bytes, value : V) : V
    insert(key, value)
    value
  end

  # Stores *value* under *key* and returns the value it replaces, or `nil`
  # if the tree did not hold *key*.
  #
  # ```
  # tree = RadixTree(Int32).new
  # tree.put("a", 1) # => nil
  # tree.put("a", 2) # => 1
  # ```
  def put(key : String | Bytes, value : V) : V?
    replaced, old = insert(key, value)
    old if replaced
  end

  # Returns the value for *key*. If the tree does not hold *key*, stores
  # *value* under it first.
  def put_if_absent(key : String | Bytes, value : V) : V
    put_if_absent(key) { value }
  end

  # Returns the value for *key*. If the tree does not hold *key*, stores the
  # block's result (given *key*) under it first.
  #
  # ```
  # tree = RadixTree(Int32).new
  # tree.put_if_absent("abc", &.size) # => 3
  # tree.put_if_absent("abc") { 0 }   # => 3
  # ```
  def put_if_absent(key : String | Bytes, & : String | Bytes -> V) : V
    node = find_node(key.to_unsafe, key.bytesize)
    return node.value.value unless node.null?
    # The block runs before the insertion, so it may change the tree.
    value = yield key
    insert(key, value)
    value
  end

  # Stores *value* under *key*. Returns whether a value was replaced, and
  # that value.
  private def insert(key : String | Bytes, value : V) : {Bool, V}
    ptr = key.to_unsafe
    len = key.bytesize
    node_ptr = root
    pos = 0
    while true
      node = node_ptr.value
      if pos == len
        if node.key
          old = node.value
          node.value = value
          node_ptr.value = node
          return {true, old}
        end
        node.set(owned_key(key), value)
        node_ptr.value = node
        @size += 1
        return {false, value}
      end

      byte = ptr[pos]
      i = node.lower_bound(byte)
      if i == node.count || node.first_bytes[i] != byte
        stored = owned_key(key)
        node.insert_edge(i, byte, Node(V).new(stored.to_unsafe + pos, len - pos, stored, value))
        node_ptr.value = node
        @size += 1
        return {false, value}
      end

      child_ptr = node.edges + i
      child = child_ptr.value
      label = child.label
      limit = Math.min(child.label_size, len - pos)
      common = 1
      while common < limit && label[common] == ptr[pos + common]
        common += 1
      end

      if common < child.label_size
        # Split the edge: a new node takes the common part of the label and
        # the child moves into its block.
        middle = Node(V).new(label, common)
        child.relabel(label + common, child.label_size - common)
        middle.insert_edge(0, label[common], child)
        child_ptr.value = middle
      end
      node_ptr = child_ptr
      pos += common
    end
  end

  private def owned_key(key : String) : String
    key
  end

  private def owned_key(key : Bytes) : String
    String.new(key)
  end

  private def key_string(key : String) : String
    key
  end

  private def key_string(key : Bytes) : String
    String.new(key)
  end

  # Removes *key* and returns its value, or `nil` if the tree did not hold
  # it.
  #
  # ```
  # tree = RadixTree(Int32){"a" => 1, "ab" => 2}
  # tree.delete("a") # => 1
  # tree.delete("a") # => nil
  # tree.keys        # => ["ab"]
  # ```
  def delete(key : String | Bytes) : V?
    delete(key) { nil }
  end

  # Removes *key* and returns its value. If the tree does not hold *key*,
  # returns the block's result (given *key*) instead.
  def delete(key : String | Bytes, &)
    ptr = key.to_unsafe
    len = key.bytesize
    grandparent = Pointer(Node(V)).null
    parent = Pointer(Node(V)).null
    parent_index = 0
    parent_start = 0
    node_ptr = root
    start = 0
    pos = 0
    # Descends like `find_node`, remembering the parent and grandparent.
    while pos < len
      i = node_ptr.value.index(ptr[pos])
      return yield key if i < 0
      grandparent = parent
      parent, parent_index, parent_start = node_ptr, i, start
      node_ptr = node_ptr.value.edges + i
      start = pos
      pos += node_ptr.value.label_size
    end
    node = node_ptr.value
    stored = node.key
    return yield key unless pos == len && stored && stored.to_unsafe.memcmp(ptr, len) == 0

    value = node.value
    @size -= 1
    if parent.null? || node.count >= 2
      node.unset
      node_ptr.value = node
    elsif node.count == 1
      node_ptr.value = merged(node, start)
    else
      parent_node = parent.value
      parent_node.remove_edge(parent_index)
      if !grandparent.null? && parent_node.count == 1 && !parent_node.key
        parent.value = merged(parent_node, parent_start)
      else
        parent.value = parent_node
      end
    end
    value
  end

  # Returns the only child of *node*, which holds no value (or is losing
  # it), with *node*'s label prepended. *start* is the offset of *node*'s
  # label within its keys. The merged label is taken from a key below the
  # child, which spells it out, so merging does not allocate.
  private def merged(node : Node(V), start : Int32) : Node(V)
    child = node.edges.value
    child.relabel(child.some_key.to_unsafe + start, node.label_size + child.label_size)
    child
  end

  # Returns the longest key in the tree that is a prefix of *key* (or is
  # *key* itself) and its value, or `nil` if there is none.
  #
  # ```
  # tree = RadixTree(Int32){"/" => 1, "/api" => 2, "/api/v1" => 3}
  # tree.longest_prefix("/api/v2/users") # => {"/api", 2}
  # tree.longest_prefix("/api/v1")       # => {"/api/v1", 3}
  # tree.longest_prefix("index")         # => nil
  # ```
  def longest_prefix(key : String | Bytes) : {String, V}?
    node = longest_prefix_node(key.to_unsafe, key.bytesize)
    {node.value.stored_key, node.value.value} unless node.null?
  end

  # Returns the value of the longest key in the tree that is a prefix of
  # *key* (or is *key* itself), or `nil` if there is none.
  #
  # ```
  # tree = RadixTree(Int32){"/" => 1, "/api" => 2}
  # tree.longest_prefix_value("/api/v2") # => 2
  # ```
  def longest_prefix_value(key : String | Bytes) : V?
    node = longest_prefix_node(key.to_unsafe, key.bytesize)
    node.value.value unless node.null?
  end

  # Returns the longest key in the tree that is a prefix of *key* (or is
  # *key* itself), or `nil` if there is none.
  def longest_prefix_key(key : String | Bytes) : String?
    node = longest_prefix_node(key.to_unsafe, key.bytesize)
    node.value.stored_key unless node.null?
  end

  private def longest_prefix_node(ptr : Pointer(UInt8), len : Int32) : Pointer(Node(V))
    # First pass: descend through the nodes whose path fits in the key,
    # skipping labels, then check the skipped bytes once. When they all
    # match, which is the common case, the deepest node holding a value is
    # the answer.
    node = root
    best = node.value.key ? node : Pointer(Node(V)).null
    pos = 0
    start = 0
    while pos < len
      child = node.value.child(ptr[pos])
      break if child.null?
      size = child.value.label_size
      break if len - pos < size
      start = pos
      pos += size
      node = child
      best = node if node.value.key
    end
    return best if pos == 0
    limit = common_prefix(node.value.label - start, ptr, pos)
    return best if limit == pos
    longest_prefix_node_within(ptr, limit)
  end

  # The deepest node holding a value whose path is a prefix of the first
  # *limit* bytes at *ptr*, which are known to lie on a path of the tree.
  private def longest_prefix_node_within(ptr : Pointer(UInt8), limit : Int32) : Pointer(Node(V))
    node = root
    best = node.value.key ? node : Pointer(Node(V)).null
    pos = 0
    while pos < limit
      child = node.value.child(ptr[pos])
      break if child.null?
      size = child.value.label_size
      break if limit - pos < size
      pos += size
      node = child
      best = node if node.value.key
    end
    best
  end

  # Returns how many leading bytes of the key at *ptr* (at most *len*) are
  # spelled by nodes whose path fits in the key.
  private def prefix_limit(ptr : Pointer(UInt8), len : Int32) : Int32
    node = root
    pos = 0
    start = 0
    while pos < len
      child = node.value.child(ptr[pos])
      break if child.null?
      size = child.value.label_size
      break if len - pos < size
      start = pos
      pos += size
      node = child
    end
    return 0 if pos == 0
    common_prefix(node.value.label - start, ptr, pos)
  end

  # Yields each key in the tree that is a prefix of *key* (or is *key*
  # itself) with its value, shortest first.
  #
  # ```
  # tree = RadixTree(Int32){"a" => 1, "ab" => 2, "abc" => 3, "b" => 4}
  # tree.each_prefix("abd") { |key, value| puts "#{key}: #{value}" }
  # ```
  #
  # Output:
  #
  # ```text
  # a: 1
  # ab: 2
  # ```
  def each_prefix(key : String | Bytes, & : {String, V} ->) : Nil
    ptr = key.to_unsafe
    limit = prefix_limit(ptr, key.bytesize)
    node = root.value
    yield({node.stored_key, node.value}) if node.key
    pos = 0
    while pos < limit
      child = node.child(ptr[pos])
      break if child.null?
      node = child.value
      break if limit - pos < node.label_size
      pos += node.label_size
      yield({node.stored_key, node.value}) if node.key
    end
  end

  # Returns the keys in the tree that are a prefix of *key* (or are *key*
  # itself) with their values, shortest first.
  def prefixes_of(key : String | Bytes) : Array({String, V})
    entries = [] of {String, V}
    each_prefix(key) { |entry| entries << entry }
    entries
  end

  # Returns the topmost node whose keys all start with the given prefix,
  # or a null pointer if no key does.
  private def subtree(ptr : Pointer(UInt8), len : Int32) : Pointer(Node(V))
    node = root
    pos = 0
    start = 0
    while pos < len
      child = node.value.child(ptr[pos])
      return child if child.null?
      start = pos
      pos += child.value.label_size
      node = child
    end
    if len > 0
      # Check the skipped label bytes, as in `find_node`.
      return Pointer(Node(V)).null unless common_prefix(node.value.label - start, ptr, len) == len
    end
    return Pointer(Node(V)).null if node.value.count == 0 && !node.value.key
    node
  end

  # Yields the nodes at or below *start* that hold a value, in byte-wise
  # key order. Same traversal as `Walker`, with its state in locals.
  private def each_node(start : Pointer(Node(V)), & : Pointer(Node(V)) ->) : Nil
    return if start.null?
    node = start
    current = node.value
    yield node if current.key
    edges = current.edges
    count = current.count
    index = 0
    stack = Pointer(Pointer(Node(V))).null
    indices = Pointer(Int32).null
    depth = 0
    capacity = 0
    while true
      while index < count
        child = edges + index
        index += 1
        current = child.value
        if current.count == 0
          yield child if current.key
        else
          if depth == capacity
            capacity = capacity == 0 ? 16 : capacity * 2
            stack = stack.realloc(capacity)
            indices = indices.realloc(capacity)
          end
          stack[depth] = node
          indices[depth] = index
          depth += 1
          node = child
          edges = current.edges
          count = current.count
          index = 0
          yield child if current.key
        end
      end
      break if depth == 0
      depth -= 1
      node = stack[depth]
      index = indices[depth]
      current = node.value
      edges = current.edges
      count = current.count
    end
  end

  # Yields each key in the tree that starts with *prefix* with its value,
  # in byte-wise key order.
  #
  # Finding the first key costs O(*prefix*.bytesize); each further key
  # costs amortized O(1).
  #
  # ```
  # tree = RadixTree(Int32){"car" => 1, "cart" => 2, "cat" => 3, "dog" => 4}
  # tree.each_with_prefix("car") { |key, value| puts "#{key}: #{value}" }
  # ```
  #
  # Output:
  #
  # ```text
  # car: 1
  # cart: 2
  # ```
  def each_with_prefix(prefix : String | Bytes, & : {String, V} ->) : Nil
    each_node(subtree(prefix.to_unsafe, prefix.bytesize)) do |node|
      yield({node.value.stored_key, node.value.value})
    end
  end

  # Returns an iterator over the keys in the tree that start with *prefix*
  # and their values, in byte-wise key order.
  #
  # ```
  # tree = RadixTree(Int32){"car" => 1, "cart" => 2, "cat" => 3}
  # tree.with_prefix("ca").map(&.[0]).to_a # => ["car", "cart", "cat"]
  # ```
  def with_prefix(prefix : String | Bytes) : Iterator({String, V})
    EntryIterator(V).new(Walker(V).new(subtree(prefix.to_unsafe, prefix.bytesize)))
  end

  # Yields each key in the tree that starts with *prefix*, in byte-wise
  # order.
  def each_key_with_prefix(prefix : String | Bytes, & : String ->) : Nil
    each_node(subtree(prefix.to_unsafe, prefix.bytesize)) do |node|
      yield node.value.stored_key
    end
  end

  # Returns the keys in the tree that start with *prefix*, in byte-wise
  # order.
  #
  # ```
  # tree = RadixTree(Int32){"car" => 1, "cart" => 2, "cat" => 3}
  # tree.keys_with_prefix("car") # => ["car", "cart"]
  # ```
  def keys_with_prefix(prefix : String | Bytes) : Array(String)
    keys = [] of String
    each_key_with_prefix(prefix) { |key| keys << key }
    keys
  end

  # Yields each key and value in byte-wise key order.
  #
  # ```
  # tree = RadixTree(Int32){"b" => 2, "a" => 1}
  # tree.each { |key, value| puts "#{key}: #{value}" }
  # ```
  #
  # Output:
  #
  # ```text
  # a: 1
  # b: 2
  # ```
  def each(& : {String, V} ->) : Nil
    each_node(root) do |node|
      yield({node.value.stored_key, node.value.value})
    end
  end

  # Returns an iterator over the keys and values in byte-wise key order.
  def each : Iterator({String, V})
    EntryIterator(V).new(Walker(V).new(root))
  end

  # Yields each key in byte-wise order.
  def each_key(& : String ->) : Nil
    each_node(root) do |node|
      yield node.value.stored_key
    end
  end

  # Returns an iterator over the keys in byte-wise order.
  def each_key : Iterator(String)
    KeyIterator(V).new(Walker(V).new(root))
  end

  # Yields each value, in byte-wise order of the keys.
  def each_value(& : V ->) : Nil
    each_node(root) do |node|
      yield node.value.value
    end
  end

  # Returns an iterator over the values, in byte-wise order of the keys.
  def each_value : Iterator(V)
    ValueIterator(V).new(Walker(V).new(root))
  end

  # Returns the keys in byte-wise order.
  def keys : Array(String)
    keys = Array(String).new(@size)
    each_key { |key| keys << key }
    keys
  end

  # Returns the values, in byte-wise order of the keys.
  def values : Array(V)
    values = Array(V).new(@size)
    each_value { |value| values << value }
    values
  end

  # Returns the keys and values in byte-wise key order.
  def to_a : Array({String, V})
    entries = Array({String, V}).new(@size)
    each { |entry| entries << entry }
    entries
  end

  # Returns a `Hash` with the same keys and values.
  def to_h : Hash(String, V)
    hash = Hash(String, V).new(initial_capacity: @size)
    each { |key, value| hash[key] = value }
    hash
  end

  # Returns `true` if *other* holds the same keys with equal values.
  def ==(other : RadixTree) : Bool
    return true if same?(other)
    return false unless size == other.size
    mine = Walker(V).new(root)
    theirs = other.walker
    until (a = mine.next_node).null?
      b = theirs.next_node
      return false if b.null?
      return false unless a.value.key == b.value.key && a.value.value == b.value.value
    end
    true
  end

  # :nodoc:
  protected def walker
    Walker(V).new(root)
  end

  # See `Object#hash(hasher)`
  def hash(hasher)
    hasher = @size.hash(hasher)
    each { |entry| hasher = entry.hash(hasher) }
    hasher
  end

  # Returns a copy of the tree with the same keys and values (a shallow
  # copy). Changing either tree afterwards leaves the other as is.
  def dup : self
    copy = RadixTree(V).new
    copy.replace_root(@root.deep_copy, @size)
    copy
  end

  # Returns a copy of the tree whose values are cloned too.
  def clone : self
    copy = RadixTree(V).new
    each { |key, value| copy[key] = value.clone }
    copy
  end

  # :nodoc:
  protected def replace_root(@root : Node(V), @size : Int32) : Nil
  end

  def to_s(io : IO) : Nil
    io << "RadixTree{"
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
    pp.list("RadixTree{", self, "}") do |(key, value)|
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
    count = 0
    raise "root has a label" unless @root.label_size == 0
    nodes = [{@root, ""}]
    while entry = nodes.pop?
      node, path = entry
      unless path.empty?
        raise "empty label" unless node.label_size > 0
        unless node.key || node.count >= 2
          raise "uncompressed node #{path.inspect} (#{node.count} children, no value)"
        end
        start = path.bytesize - node.label_size
        raise "label does not spell the path" unless Slice.new(node.label - start, path.bytesize) == path.to_slice
      end
      if key = node.key
        count += 1
        raise "key #{key.inspect} stored at #{path.inspect}" unless key.to_slice == path.to_slice
      end
      bytes = node.first_bytes
      node.count.times do |i|
        child = node.edges[i]
        raise "first byte mismatch" unless bytes[i] == child.label[0]
        raise "children out of order" if i > 0 && bytes[i - 1] >= bytes[i]
        label = Slice.new(child.label, child.label_size)
        nodes << {child, String.build { |io| io << path; io.write(label) }}
      end
    end
    raise "size #{@size}, counted #{count}" unless count == @size
  end

  # :nodoc:
  class EntryIterator(V)
    include Iterator({String, V})

    def initialize(@walker : Walker(V))
    end

    def next
      node = @walker.next_node
      node.null? ? stop : {node.value.stored_key, node.value.value}
    end
  end

  # :nodoc:
  class KeyIterator(V)
    include Iterator(String)

    def initialize(@walker : Walker(V))
    end

    def next
      node = @walker.next_node
      node.null? ? stop : node.value.stored_key
    end
  end

  # :nodoc:
  class ValueIterator(V)
    include Iterator(V)

    def initialize(@walker : Walker(V))
    end

    def next
      node = @walker.next_node
      node.null? ? stop : node.value.value
    end
  end
end
