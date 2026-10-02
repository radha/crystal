require "rapidhash"

# A `CountMinSketch` estimates how often each item occurs in a stream using
# a fixed amount of memory, independent of the number of distinct items.
# `count` never underestimates: it returns the true count plus an error that,
# with probability at least `1 - delta`, is at most `epsilon * total`.
#
# ```
# require "count_min_sketch"
#
# words = CountMinSketch.new(epsilon: 0.001, delta: 0.01)
# "the cat and the hat and the bat".split.each { |word| words.add(word) }
# words.count("the") # => 3
# words.count("dog") # => 0 (or, rarely, a small overestimate)
#
# bytes_per_ip = CountMinSketch.new(epsilon: 0.0001, delta: 0.001)
# bytes_per_ip.add("10.0.0.1", 1500)
# ```
#
# The sketch is a `depth × width` grid of counters. Each row maps an item to
# one counter; `add` increments the item's counter in every row and `count`
# returns the smallest of them. With `conservative: true`, `add` only raises
# counters that are below the item's new estimate ("conservative update"),
# which greatly reduces overestimation on skewed streams; such sketches still
# merge, and `count` keeps its guarantee, but a merged result is no longer
# exactly the sketch of the combined stream.
#
# Items are hashed with `Rapidhash.of`, so strings, bytes, chars, integers
# and floats work out of the box (integers and floats by value: `1` and
# `1_i64` are the same item), and other types can define
# `rapidhash(seed : UInt64) : UInt64`. The hash is stable across processes
# and machines, so a sketch persisted with `to_bytes` stays valid. Counters
# saturate at `UInt64::MAX` instead of overflowing.
#
# A sketch is not thread-safe; guard concurrent writers with a `Mutex`.
#
# NOTE: To use `CountMinSketch`, you must explicitly import it with `require "count_min_sketch"`
class CountMinSketch
  # The largest supported `depth`.
  MAX_DEPTH = 64

  # The largest supported number of counters, `width * depth`: 2^28
  # (2 GiB).
  MAX_COUNTERS = 1 << 28

  # The first bytes of `to_bytes`.
  MAGIC = "CRCM"

  # The version of the `to_bytes` layout.
  FORMAT_VERSION = 1_u8

  private HEADER_SIZE = 40

  # The number of counters per row.
  getter width : Int32

  # The number of rows, each with an independent hash.
  getter depth : Int32

  # The seed of the item hash. Sketches only merge with sketches of the same
  # seed.
  getter seed : UInt64

  # The sum of every count added (saturating at `UInt64::MAX`).
  getter total : UInt64

  # Whether `add` uses conservative update.
  getter? conservative : Bool

  @counters : Slice(UInt64)
  @premixed : UInt64

  # Creates a sketch whose `count` overestimates by at most `epsilon *
  # total`, with probability at least `1 - delta`: `width` is `ceil(e /
  # epsilon)` and `depth` is `ceil(ln(1 / delta))`.
  #
  # ```
  # sketch = CountMinSketch.new(epsilon: 0.001, delta: 0.01)
  # sketch.width # => 2719
  # sketch.depth # => 5
  # ```
  #
  # Raises `ArgumentError` unless *epsilon* and *delta* are strictly
  # between 0 and 1, or if the sketch would be too large.
  def self.new(*, epsilon : Float64, delta : Float64, seed : UInt64 = 0_u64, conservative : Bool = false) : self
    raise ArgumentError.new("Epsilon must be between 0 and 1 (exclusive), not #{epsilon}") unless 0.0 < epsilon < 1.0
    raise ArgumentError.new("Delta must be between 0 and 1 (exclusive), not #{delta}") unless 0.0 < delta < 1.0
    width = (Math::E / epsilon).ceil
    depth = Math.log(1.0 / delta).ceil.clamp(1.0, MAX_DEPTH.to_f64)
    raise ArgumentError.new("Sketch too large for epsilon #{epsilon}") if width * depth > MAX_COUNTERS
    new(width: width.to_i32, depth: depth.to_i32, seed: seed, conservative: conservative)
  end

  # Creates a sketch with exactly *width* counters in each of *depth* rows.
  #
  # Raises `ArgumentError` unless both are positive, *depth* is at most
  # `MAX_DEPTH` and there are at most `MAX_COUNTERS` counters.
  def initialize(*, width : Int, depth : Int, seed : UInt64 = 0_u64, conservative : Bool = false)
    raise ArgumentError.new("Width must be positive, not #{width}") unless width > 0
    raise ArgumentError.new("Depth must be in 1..#{MAX_DEPTH}, not #{depth}") unless 0 < depth <= MAX_DEPTH
    if width.to_i64 * depth > MAX_COUNTERS
      raise ArgumentError.new("Sketch too large: #{width} × #{depth} counters (max #{MAX_COUNTERS})")
    end
    @width = width.to_i32
    @depth = depth.to_i32
    @seed = seed
    @conservative = conservative
    @total = 0_u64
    @premixed = Rapidhash.premix(seed)
    @counters = Slice(UInt64).new(@width * @depth)
  end

  protected def initialize(@width : Int32, @depth : Int32, @seed : UInt64, @conservative : Bool, @total : UInt64, @counters : Slice(UInt64))
    @premixed = Rapidhash.premix(@seed)
  end

  # Adds *count* occurrences of *item* and returns the item's new estimated
  # count.
  #
  # ```
  # sketch = CountMinSketch.new(width: 1000, depth: 4)
  # sketch.add("a")    # => 1
  # sketch.add("a", 5) # => 6
  # ```
  #
  # Raises `ArgumentError` if *count* is negative.
  def add(item, count : Int = 1) : UInt64
    raise ArgumentError.new("Count must not be negative, not #{count}") if count < 0
    amount = count.to_u64
    @total = saturating_add(@total, amount)
    hash = Rapidhash.of_premixed(item, @premixed)

    if @conservative
      estimate = saturating_add(min_counter(hash), amount)
      each_counter(hash) do |ptr|
        ptr.value = estimate if ptr.value < estimate
      end
      estimate
    else
      estimate = UInt64::MAX
      each_counter(hash) do |ptr|
        value = saturating_add(ptr.value, amount)
        ptr.value = value
        estimate = value if value < estimate
      end
      estimate
    end
  end

  # Adds one occurrence of *item* and returns `self`.
  def <<(item) : self
    add(item)
    self
  end

  # Returns the estimated number of occurrences of *item*: never less than
  # the true count.
  def count(item) : UInt64
    min_counter(Rapidhash.of_premixed(item, @premixed))
  end

  # :ditto:
  def [](item) : UInt64
    count(item)
  end

  # Returns `true` if nothing has been added since creation or `clear`.
  def empty? : Bool
    @total == 0 && @counters.all?(&.zero?)
  end

  # Resets every counter.
  def clear : self
    @counters.fill(0_u64)
    @total = 0_u64
    self
  end

  # Adds the counts of *other* to `self`, so that `self` estimates the
  # combined stream. Merging is exact unless a sketch uses conservative
  # update, in which case the result still never underestimates.
  #
  # Raises `ArgumentError` unless both sketches have the same `width`,
  # `depth` and `seed`.
  def merge!(other : CountMinSketch) : self
    unless @width == other.width && @depth == other.depth && @seed == other.seed
      raise ArgumentError.new("Cannot merge CountMinSketches with different parameters " \
                              "(#{@width}×#{@depth}, seed #{@seed} vs " \
                              "#{other.width}×#{other.depth}, seed #{other.seed})")
    end
    mine = @counters.to_unsafe
    theirs = other.@counters.to_unsafe
    @counters.size.times do |i|
      mine[i] = saturating_add(mine[i], theirs[i])
    end
    @total = saturating_add(@total, other.total)
    self
  end

  # Returns a new sketch estimating the combined stream of `self` and
  # *other*. See `merge!`.
  def +(other : CountMinSketch) : CountMinSketch
    dup.merge!(other)
  end

  # Returns `true` if both sketches have the same parameters and counters.
  def ==(other : CountMinSketch) : Bool
    @width == other.width && @depth == other.depth && @seed == other.seed &&
      @conservative == other.conservative? && @total == other.total &&
      @counters == other.@counters
  end

  # Returns a copy that can be changed independently of `self`.
  def dup : CountMinSketch
    CountMinSketch.new(@width, @depth, @seed, @conservative, @total, @counters.dup)
  end

  # :ditto:
  def clone : CountMinSketch
    dup
  end

  # Returns the sketch serialized in a stable, versioned binary layout that
  # `from_bytes` reads back, here or in any other process:
  #
  # | Offset | Size  | Field                                                  |
  # |--------|-------|--------------------------------------------------------|
  # | 0      | 4     | magic `"CRCM"`                                         |
  # | 4      | 1     | layout version (`1`)                                   |
  # | 5      | 1     | algorithm (`1`: rapidhash V3, enhanced double hashing) |
  # | 6      | 1     | flags (bit 0: `conservative?`)                         |
  # | 7      | 1     | reserved, zero                                         |
  # | 8      | 4     | `width`                                                |
  # | 12     | 4     | `depth`                                                |
  # | 16     | 8     | `seed`                                                 |
  # | 24     | 8     | `total`                                                |
  # | 32     | 8     | reserved, zero                                         |
  # | 40     | 8 × n | the `n = width × depth` counters, row by row           |
  #
  # Integers are little-endian.
  def to_bytes : Bytes
    io = IO::Memory.new(HEADER_SIZE + @counters.bytesize)
    to_io(io)
    io.to_slice
  end

  # Writes `to_bytes` to *io*.
  def to_io(io : IO) : Nil
    io.write(MAGIC.to_slice)
    io.write_byte(FORMAT_VERSION)
    io.write_byte(1_u8)
    io.write_byte(@conservative ? 1_u8 : 0_u8)
    io.write_byte(0_u8)
    io.write_bytes(@width.to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(@depth.to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(@seed, IO::ByteFormat::LittleEndian)
    io.write_bytes(@total, IO::ByteFormat::LittleEndian)
    io.write_bytes(0_u64, IO::ByteFormat::LittleEndian)
    # Crystal targets are little-endian, so the counters are already in
    # order.
    io.write(@counters.to_unsafe_bytes)
  end

  # Reads a sketch written by `to_bytes`.
  #
  # Raises `ArgumentError` if *bytes* is not a valid sketch.
  def self.from_bytes(bytes : Bytes) : CountMinSketch
    io = IO::Memory.new(bytes, writable: false)
    sketch = from_io(io)
    raise ArgumentError.new("Invalid CountMinSketch: trailing bytes") unless io.pos == bytes.size
    sketch
  rescue IO::EOFError
    raise ArgumentError.new("Invalid CountMinSketch: truncated")
  end

  # Reads a sketch written by `to_io`.
  #
  # Raises `ArgumentError` if the data is not a valid sketch, and
  # `IO::EOFError` if *io* ends early.
  def self.from_io(io : IO) : CountMinSketch
    header = Bytes.new(HEADER_SIZE)
    io.read_fully(header)
    raise ArgumentError.new("Invalid CountMinSketch: bad magic") unless header[0, 4] == MAGIC.to_slice
    raise ArgumentError.new("Unsupported CountMinSketch version #{header[4]}") unless header[4] == FORMAT_VERSION
    raise ArgumentError.new("Unsupported CountMinSketch algorithm #{header[5]}") unless header[5] == 1
    raise ArgumentError.new("Invalid CountMinSketch: unknown flags #{header[6]}") unless header[6] <= 1
    format = IO::ByteFormat::LittleEndian
    width = format.decode(UInt32, header[8, 4])
    depth = format.decode(UInt32, header[12, 4])
    seed = format.decode(UInt64, header[16, 8])
    total = format.decode(UInt64, header[24, 8])
    unless 0 < width && 0 < depth <= MAX_DEPTH && width.to_u64 * depth <= MAX_COUNTERS
      raise ArgumentError.new("Invalid CountMinSketch: #{width} × #{depth} counters")
    end

    counters = Slice(UInt64).new((width * depth).to_i32)
    io.read_fully(counters.to_unsafe_bytes)
    new(width.to_i32, depth.to_i32, seed, header[6] == 1, total, counters)
  end

  def inspect(io : IO) : Nil
    io << "#<CountMinSketch width=" << @width << " depth=" << @depth << " seed=" << @seed
    io << " conservative=" << @conservative << " total=" << @total << '>'
  end

  @[AlwaysInline]
  private def min_counter(hash : UInt64) : UInt64
    estimate = UInt64::MAX
    each_counter(hash) do |ptr|
      estimate = ptr.value if ptr.value < estimate
    end
    estimate
  end

  # Yields a pointer to the item's counter in each row. The column sequence
  # is enhanced double hashing (Dillinger & Manolios) over one 64-bit hash,
  # mapped to `0...width` by a multiply-shift instead of a modulo (Lemire).
  @[AlwaysInline]
  private def each_counter(hash : UInt64, &)
    a = hash
    b = (hash >> 32) | (hash << 32)
    width = @width.to_u64!
    row = @counters.to_unsafe
    @depth.times do |i|
      column = ((a.to_u128 &* width) >> 64).to_u64!
      yield row + column
      row += @width
      a &+= b
      b &+= i.to_u64!
    end
  end

  @[AlwaysInline]
  private def saturating_add(a : UInt64, b : UInt64) : UInt64
    sum = a &+ b
    sum < a ? UInt64::MAX : sum
  end
end
