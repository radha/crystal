# A `Heap` is a [binary heap](https://en.wikipedia.org/wiki/Binary_heap)
# priority queue over elements of type *T*: `push` adds an element and `pop`
# removes the smallest one, each in O(log n), while `peek` reads the smallest
# in O(1).
#
# By default elements are ordered with `<=>`, so `pop` returns the minimum.
# Pass a comparator block to change the order, for example to build a
# max-heap or to order elements that do not define `<=>`:
#
# ```
# require "heap"
#
# heap = Heap(Int32).new
# heap << 3 << 1 << 2
# heap.pop # => 1
# heap.pop # => 2
#
# max = Heap(Int32).new { |a, b| b <=> a }
# max.concat([3, 1, 2])
# max.pop # => 3
#
# Heap.new([5, 3, 8]).peek # => 3
# ```
#
# Building a heap from a collection with `Heap.new(elements)` runs in O(n),
# faster than pushing the elements one by one.
#
# Iterating a heap with `each` or `to_a` visits the elements in an
# unspecified order; only `pop` yields them in priority order.
#
# NOTE: To use `Heap`, you must explicitly import it with `require "heap"`
class Heap(T)
  include Enumerable(T)

  # The heap is stored in an array in the usual implicit layout: the children
  # of the element at index `i` sit at `2i + 1` and `2i + 2`, and every
  # element orders at or before its children.
  @buffer : Array(T)
  @compare : Proc(T, T, Int32?)?

  # Creates an empty heap ordered by `<=>`.
  #
  # *initial_capacity* presizes the underlying storage; give an estimate of
  # the largest size the heap will reach to avoid reallocations.
  #
  # ```
  # heap = Heap(Int32).new(64)
  # heap.push(2).push(1)
  # heap.pop # => 1
  # ```
  def initialize(initial_capacity : Int = 0)
    {% raise "Heap(#{T}) needs a comparator block because #{T} does not define `<=>`" unless (T.union? ? T.union_types.all?(&.has_method?("<=>")) : T.has_method?("<=>")) %}
    @buffer = Array(T).new(initial_capacity)
    @compare = nil
  end

  # Creates an empty heap ordered by the *compare* block, which receives two
  # elements and returns a negative number when the first should be popped
  # before the second, positive when after, and zero when either may come
  # first (like `<=>`).
  #
  # ```
  # heap = Heap(String).new { |a, b| a.size <=> b.size }
  # heap << "ccc" << "a" << "bb"
  # heap.pop # => "a"
  # ```
  def initialize(initial_capacity : Int = 0, &compare : T, T -> Int32?)
    @buffer = Array(T).new(initial_capacity)
    @compare = compare
  end

  # Creates a heap ordered by `<=>` holding every element of *elements*,
  # in O(n) time. *elements* is not modified.
  #
  # ```
  # heap = Heap.new([5, 3, 8])
  # heap.pop # => 3
  # ```
  def initialize(elements : Enumerable(T))
    {% raise "Heap(#{T}) needs a comparator block because #{T} does not define `<=>`" unless (T.union? ? T.union_types.all?(&.has_method?("<=>")) : T.has_method?("<=>")) %}
    @buffer = Array(T).new.concat(elements)
    @compare = nil
    heapify
  end

  # Creates a heap ordered by the *compare* block (see `.new(&)`) holding
  # every element of *elements*, in O(n) time. *elements* is not modified.
  def initialize(elements : Enumerable(T), &compare : T, T -> Int32?)
    @buffer = Array(T).new.concat(elements)
    @compare = compare
    heapify
  end

  protected def initialize(@buffer : Array(T), @compare : Proc(T, T, Int32?)?)
  end

  # Returns the number of elements in the heap.
  def size : Int32
    @buffer.size
  end

  # Returns `true` if the heap holds no elements.
  def empty? : Bool
    @buffer.empty?
  end

  # Adds *value* to the heap and returns `self`.
  #
  # ```
  # heap = Heap(Int32).new
  # heap.push(2).push(1)
  # heap.pop # => 1
  # ```
  def push(value : T) : self
    @buffer << value
    with_less sift_up(@buffer.size - 1)
    self
  end

  # Adds *value* to the heap and returns `self`. Same as `push`.
  #
  # ```
  # heap = Heap(Int32).new
  # heap << 2 << 1
  # heap.pop # => 1
  # ```
  def <<(value : T) : self
    push(value)
  end

  # Adds every element of *elements* to the heap and returns `self`.
  #
  # ```
  # heap = Heap.new([5])
  # heap.concat([3, 9]).concat(1..2)
  # heap.pop # => 1
  # ```
  def concat(elements : Enumerable(T)) : self
    elements.each { |value| push(value) }
    self
  end

  # :ditto:
  def concat(elements : Indexable(T)) : self
    if elements.size > @buffer.size
      # Rebuilding is O(n + k), cheaper than k pushes once k dominates.
      @buffer.concat(elements)
      heapify
    else
      elements.each { |value| push(value) }
    end
    self
  end

  # Removes and returns the smallest element.
  #
  # Raises `IndexError` if the heap is empty.
  #
  # ```
  # heap = Heap.new([4, 2, 9])
  # heap.pop # => 2
  # heap.pop # => 4
  # heap.pop # => 9
  # heap.pop # raises IndexError
  # ```
  def pop : T
    pop { raise IndexError.new }
  end

  # Removes and returns the smallest element, or `nil` if the heap is empty.
  #
  # ```
  # heap = Heap.new([4, 2])
  # heap.pop? # => 2
  # heap.pop? # => 4
  # heap.pop? # => nil
  # ```
  def pop? : T?
    pop { nil }
  end

  # Removes and returns the smallest element, or the block's value if the
  # heap is empty.
  def pop(&)
    size = @buffer.size
    return yield if size == 0

    last = @buffer.pop
    return last if size == 1

    top = @buffer.to_unsafe[0]
    with_less sift_down_to_bottom(last)
    top
  end

  # Returns the smallest element without removing it.
  #
  # Raises `IndexError` if the heap is empty.
  #
  # ```
  # heap = Heap.new([4, 2, 9])
  # heap.peek # => 2
  # heap.size # => 3
  # ```
  def peek : T
    @buffer.first { raise IndexError.new }
  end

  # Returns the smallest element without removing it, or `nil` if the heap is
  # empty.
  #
  # ```
  # Heap.new([4, 2]).peek? # => 2
  # Heap(Int32).new.peek?  # => nil
  # ```
  def peek? : T?
    @buffer.first?
  end

  # Removes and returns the smallest element, then adds *value*, with a
  # single O(log n) sift instead of the two that `pop` followed by `push`
  # would need.
  #
  # Raises `IndexError` if the heap is empty.
  #
  # ```
  # heap = Heap.new([1, 5, 3])
  # heap.replace_top(4) # => 1
  # heap.pop            # => 3
  # ```
  def replace_top(value : T) : T
    raise IndexError.new if @buffer.empty?

    ptr = @buffer.to_unsafe
    top = ptr[0]
    ptr[0] = value
    with_less sift_down(0, @buffer.size)
    top
  end

  # Adds *value*, then removes and returns the smallest element. When *value*
  # orders at or before the current top the heap is left untouched and
  # *value* is returned, so this is cheaper than `push` followed by `pop`.
  #
  # ```
  # heap = Heap.new([3, 5])
  # heap.push_pop(1) # => 1
  # heap.push_pop(4) # => 3
  # heap.pop         # => 4
  # ```
  def push_pop(value : T) : T
    return value if @buffer.empty? || !(with_less less?(@buffer.to_unsafe[0], value))

    replace_top(value)
  end

  # Removes every element and returns `self`.
  def clear : self
    @buffer.clear
    self
  end

  # Returns a new heap holding the same elements and comparator. The
  # elements themselves are not copied.
  def dup : Heap(T)
    Heap(T).new(@buffer.dup, @compare)
  end

  # Yields every element in unspecified order.
  #
  # Use `pop` to take the elements in priority order.
  def each(& : T ->) : Nil
    @buffer.each { |value| yield value }
  end

  # Returns an array of the elements in unspecified order.
  def to_a : Array(T)
    @buffer.dup
  end

  # Prints the elements in unspecified order, wrapped in `Heap{...}`.
  def inspect(io : IO) : Nil
    executed = exec_recursive(:inspect) do
      io << "Heap{"
      @buffer.join io, ", ", &.inspect(io)
      io << '}'
    end
    io << "Heap{...}" unless executed
    nil
  end

  # :ditto:
  def to_s(io : IO) : Nil
    inspect(io)
  end

  # Restores the heap property over the whole buffer in O(n).
  private def heapify : Nil
    size = @buffer.size
    return if size < 2

    with_less heapify(size)
  end

  private def heapify(size : Int32, &) : Nil
    (size // 2 - 1).downto(0) do |i|
      sift_down(i, size) { |a, b| yield a, b }
    end
  end

  # Expands to *call* followed by a block that returns `true` when its first
  # argument must be popped before its second, either through the comparator
  # or through `<=>`. Resolving the comparator once per operation and
  # yielding keeps the per-level loop free of the nil check and of the
  # reload of `@compare` that a plain method would need after every store.
  private macro with_less(call)
    if %compare = @compare
      {{call}} { |a, b| (%compare.call(a, b) || comparison_failed(a, b)) < 0 }
    else
      {% if (T.union? ? T.union_types.all?(&.has_method?("<=>")) : T.has_method?("<=>")) %}
        {{call}} { |a, b| ((a <=> b) || comparison_failed(a, b)) < 0 }
      {% else %}
        raise "BUG: Heap(#{T}) has no comparator"
      {% end %}
    end
  end

  private def less?(a : T, b : T, &) : Bool
    yield a, b
  end

  @[NoInline]
  private def comparison_failed(a, b)
    raise ArgumentError.new("Comparison of #{a} and #{b} failed")
  end

  # Moves the element at *pos* towards the root until its parent orders at
  # or before it. The element is held aside and parents slide down into the
  # hole, so each level costs one copy instead of a swap.
  private def sift_up(pos : Int32, &) : Nil
    ptr = @buffer.to_unsafe
    elem = ptr[pos]
    while pos > 0
      parent = (pos &- 1) >> 1
      break unless yield elem, ptr[parent]
      ptr[pos] = ptr[parent]
      pos = parent
    end
    ptr[pos] = elem
  end

  # Moves the element at *pos* towards the leaves until both children order
  # at or after it, considering only the first *size* elements.
  private def sift_down(pos : Int32, size : Int32, &) : Nil
    ptr = @buffer.to_unsafe
    elem = ptr[pos]
    child = 2 &* pos &+ 1
    while child &+ 1 < size
      child &+= 1 if yield ptr[child &+ 1], ptr[child]
      break unless yield ptr[child], elem
      ptr[pos] = ptr[child]
      pos = child
      child = 2 &* pos &+ 1
    end
    if child == size &- 1 && (yield ptr[child], elem)
      ptr[pos] = ptr[child]
      pos = child
    end
    ptr[pos] = elem
  end

  # Fills the hole at the root by sliding the smaller child up at each level
  # all the way to a leaf, places *elem* there and sifts it back up. The
  # element that replaces a popped root usually belongs near the bottom, so
  # this saves the comparison against *elem* at every level that a plain
  # `sift_down` would make.
  private def sift_down_to_bottom(elem : T, &) : Nil
    ptr = @buffer.to_unsafe
    size = @buffer.size
    pos = 0
    child = 1
    while child &+ 1 < size
      child &+= 1 if yield ptr[child &+ 1], ptr[child]
      ptr[pos] = ptr[child]
      pos = child
      child = 2 &* pos &+ 1
    end
    if child == size &- 1
      ptr[pos] = ptr[child]
      pos = child
    end
    while pos > 0
      parent = (pos &- 1) >> 1
      break unless yield elem, ptr[parent]
      ptr[pos] = ptr[parent]
      pos = parent
    end
    ptr[pos] = elem
  end
end
