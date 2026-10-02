require "rapidhash"

# A `HyperLogLog` estimates the number of distinct items in a stream using a
# small, fixed amount of memory: `2 ** precision` bytes (16 KiB at the
# default precision 14) whether it has seen ten items or ten billion. The
# typical relative error is `1.04 / sqrt(2 ** precision)`, 0.81% at
# precision 14.
#
# ```
# require "hyper_log_log"
#
# visitors = HyperLogLog.new
# visitors << "alice" << "bob" << "alice"
# visitors.size # => 2
#
# 1_000_000.times { |i| visitors << i }
# visitors.size # => 1_000_002 (approximately)
# ```
#
# Sketches merge losslessly: the union of two sketches equals the sketch of
# the union of their streams, so counts can be computed per shard, per hour
# or per machine and combined later with `|` or `merge!`.
#
# Items are hashed with `Rapidhash.of`, so strings, bytes, chars, integers
# and floats work out of the box (integers and floats by value: `1` and
# `1_i64` are the same item), and other types can define
# `rapidhash(seed : UInt64) : UInt64`. The hash is stable across processes
# and machines, so a sketch persisted with `to_bytes` stays valid.
#
# The estimator is Otmar Ertl's improved estimator ("New cardinality
# estimation algorithms for HyperLogLog sketches", 2017), as used by Redis:
# it is unbiased across the whole range without empirical bias tables.
#
# A sketch is not thread-safe; guard concurrent writers with a `Mutex`.
#
# NOTE: To use `HyperLogLog`, you must explicitly import it with `require "hyper_log_log"`
class HyperLogLog
  # The smallest supported precision.
  MIN_PRECISION = 4

  # The largest supported precision.
  MAX_PRECISION = 18

  # The precision used by `new` when none is given.
  DEFAULT_PRECISION = 14

  # The first bytes of `to_bytes`.
  MAGIC = "CRHL"

  # The version of the `to_bytes` layout.
  FORMAT_VERSION = 1_u8

  private HEADER_SIZE = 16

  # The number of index bits: the sketch has `2 ** precision` registers.
  getter precision : Int32

  # The seed of the item hash. Sketches only merge with sketches of the
  # same seed.
  getter seed : UInt64

  @registers : Bytes
  @premixed : UInt64
  @cached_size : Int64?

  # Creates an empty sketch with `2 ** precision` registers.
  #
  # Raises `ArgumentError` unless *precision* is in
  # `MIN_PRECISION..MAX_PRECISION`.
  def initialize(precision : Int = DEFAULT_PRECISION, *, seed : UInt64 = 0_u64)
    unless MIN_PRECISION <= precision <= MAX_PRECISION
      raise ArgumentError.new("Precision must be in #{MIN_PRECISION}..#{MAX_PRECISION}, not #{precision}")
    end
    @precision = precision.to_i32
    @seed = seed
    @premixed = Rapidhash.premix(seed)
    @registers = Bytes.new(1 << @precision)
    @cached_size = 0_i64
  end

  protected def initialize(@precision : Int32, @seed : UInt64, @registers : Bytes)
    @premixed = Rapidhash.premix(@seed)
    @cached_size = nil
  end

  # Adds *item* and returns `self`.
  def add(item) : self
    add?(item)
    self
  end

  # :ditto:
  def <<(item) : self
    add(item)
  end

  # Adds *item* and returns `true` if a register changed, which means the
  # estimate may have changed. `false` proves nothing about whether the item
  # was seen before.
  def add?(item) : Bool
    hash = Rapidhash.of_premixed(item, @premixed)
    index = hash >> (64 - @precision)
    # The rank is the position of the first 1 bit after the index bits. The
    # sentinel bit caps it at 64 - precision + 1 when the rest is all zeros.
    rest = (hash << @precision) | (1_u64 << (@precision - 1))
    rank = rest.leading_zeros_count.to_u8! &+ 1
    ptr = @registers.to_unsafe + index
    return false unless rank > ptr.value
    ptr.value = rank
    @cached_size = nil
    true
  end

  # Returns the estimated number of distinct items added. The result is
  # cached until the sketch changes.
  def size : Int64
    @cached_size ||= estimate
  end

  # Returns `true` if no item has been added since creation or `clear`.
  def empty? : Bool
    @registers.all?(&.zero?)
  end

  # Removes every item.
  def clear : self
    @registers.fill(0_u8)
    @cached_size = 0_i64
    self
  end

  # Returns the typical relative error of `size`: `1.04 / sqrt(2 **
  # precision)`.
  def standard_error : Float64
    1.04 / Math.sqrt((1 << @precision).to_f64)
  end

  # Merges *other* into `self`, so that `self` estimates the distinct items
  # of both streams.
  #
  # Raises `ArgumentError` unless both sketches have the same `precision`
  # and `seed`.
  def merge!(other : HyperLogLog) : self
    unless @precision == other.precision && @seed == other.seed
      raise ArgumentError.new("Cannot merge HyperLogLogs with different parameters " \
                              "(precision #{@precision}, seed #{@seed} vs " \
                              "precision #{other.precision}, seed #{other.seed})")
    end
    mine = @registers.to_unsafe
    theirs = other.@registers.to_unsafe
    @registers.size.times do |i|
      mine[i] = theirs[i] if theirs[i] > mine[i]
    end
    @cached_size = nil
    self
  end

  # Returns a new sketch estimating the distinct items of both `self` and
  # *other*.
  #
  # Raises `ArgumentError` unless both sketches have the same `precision`
  # and `seed`.
  def |(other : HyperLogLog) : HyperLogLog
    dup.merge!(other)
  end

  # Returns `true` if both sketches have the same parameters and registers.
  def ==(other : HyperLogLog) : Bool
    @precision == other.precision && @seed == other.seed && @registers == other.@registers
  end

  # Returns a copy that can be changed independently of `self`.
  def dup : HyperLogLog
    copy = HyperLogLog.new(@precision, @seed, @registers.dup)
    copy.cached_size = @cached_size
    copy
  end

  # :ditto:
  def clone : HyperLogLog
    dup
  end

  protected setter cached_size : Int64?

  # Returns the sketch serialized in a stable, versioned binary layout that
  # `from_bytes` reads back, here or in any other process:
  #
  # | Offset | Size  | Field                                                 |
  # |--------|-------|-------------------------------------------------------|
  # | 0      | 4     | magic `"CRHL"`                                        |
  # | 4      | 1     | layout version (`1`)                                  |
  # | 5      | 1     | algorithm (`1`: rapidhash V3, index = high bits)      |
  # | 6      | 1     | `precision`                                           |
  # | 7      | 1     | reserved, zero                                        |
  # | 8      | 8     | `seed`, little-endian                                 |
  # | 16     | 2^p   | the registers, one byte each                          |
  def to_bytes : Bytes
    io = IO::Memory.new(HEADER_SIZE + @registers.size)
    to_io(io)
    io.to_slice
  end

  # Writes `to_bytes` to *io*.
  def to_io(io : IO) : Nil
    io.write(MAGIC.to_slice)
    io.write_byte(FORMAT_VERSION)
    io.write_byte(1_u8)
    io.write_byte(@precision.to_u8)
    io.write_byte(0_u8)
    io.write_bytes(@seed, IO::ByteFormat::LittleEndian)
    io.write(@registers)
  end

  # Reads a sketch written by `to_bytes`.
  #
  # Raises `ArgumentError` if *bytes* is not a valid sketch.
  def self.from_bytes(bytes : Bytes) : HyperLogLog
    io = IO::Memory.new(bytes, writable: false)
    sketch = from_io(io)
    raise ArgumentError.new("Invalid HyperLogLog: trailing bytes") unless io.pos == bytes.size
    sketch
  rescue IO::EOFError
    raise ArgumentError.new("Invalid HyperLogLog: truncated")
  end

  # Reads a sketch written by `to_io`.
  #
  # Raises `ArgumentError` if the data is not a valid sketch, and
  # `IO::EOFError` if *io* ends early.
  def self.from_io(io : IO) : HyperLogLog
    header = Bytes.new(HEADER_SIZE)
    io.read_fully(header)
    raise ArgumentError.new("Invalid HyperLogLog: bad magic") unless header[0, 4] == MAGIC.to_slice
    raise ArgumentError.new("Unsupported HyperLogLog version #{header[4]}") unless header[4] == FORMAT_VERSION
    raise ArgumentError.new("Unsupported HyperLogLog algorithm #{header[5]}") unless header[5] == 1
    precision = header[6].to_i32
    unless MIN_PRECISION <= precision <= MAX_PRECISION
      raise ArgumentError.new("Invalid HyperLogLog: precision #{precision}")
    end
    seed = IO::ByteFormat::LittleEndian.decode(UInt64, header[8, 8])

    registers = Bytes.new(1 << precision)
    io.read_fully(registers)
    max_rank = 64 - precision + 1
    if registers.any? { |rank| rank > max_rank }
      raise ArgumentError.new("Invalid HyperLogLog: register above #{max_rank}")
    end
    new(precision, seed, registers)
  end

  def inspect(io : IO) : Nil
    io << "#<HyperLogLog precision=" << @precision << " seed=" << @seed << " size=" << size << '>'
  end

  # Ertl's improved raw estimator over the register histogram.
  private def estimate : Int64
    q = 64 - @precision
    m = @registers.size.to_f64
    histogram = StaticArray(Int32, 64).new(0)
    @registers.each { |rank| histogram.to_unsafe[rank] += 1 }

    z = m * tau((m - histogram[q + 1]) / m)
    q.downto(1) do |k|
      z += histogram[k]
      z *= 0.5
    end
    z += m * sigma(histogram[0] / m)
    (m * m / (2.0 * Math.log(2.0)) / z).round.to_i64
  end

  private def sigma(x : Float64) : Float64
    return Float64::INFINITY if x == 1.0
    y = 1.0
    z = x
    loop do
      x *= x
      previous = z
      z += x * y
      y += y
      return z if z == previous
    end
  end

  private def tau(x : Float64) : Float64
    return 0.0 if x == 0.0 || x == 1.0
    y = 1.0
    z = 1.0 - x
    loop do
      x = Math.sqrt(x)
      previous = z
      y *= 0.5
      z -= (1.0 - x) ** 2 * y
      return z / 3.0 if z == previous
    end
  end
end
