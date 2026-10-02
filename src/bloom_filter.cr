require "rapidhash"

# A `BloomFilter` is a space-efficient probabilistic set: `includes?` never
# answers `false` for an item that was added, but may answer `true` for one
# that was not (a *false positive*), with a probability chosen when the
# filter is created. Items cannot be removed.
#
# ```
# require "bloom_filter"
#
# seen = BloomFilter.new(10_000, false_positive_rate: 0.001)
# seen << "alice" << "bob"
# seen.includes?("alice") # => true
# seen.includes?("carol") # => false (or, rarely, true)
# ```
#
# `new(capacity, false_positive_rate)` sizes the filter for *capacity* items:
# about 9.6 bits per item for a 1% rate, 14.4 for 0.1%. Adding more items
# than the capacity keeps working, but the false-positive rate rises.
#
# Items are hashed with `Rapidhash.of`, so strings, bytes, chars, integers
# and floats work out of the box (integers and floats by value: `1` and
# `1_i64` are the same item), and other types can define
# `rapidhash(seed : UInt64) : UInt64`. The hash is stable across processes
# and machines, which makes filters portable: `to_bytes` and `from_bytes`
# persist one, and `|` or `merge!` combine filters built elsewhere with the
# same parameters.
#
# A filter is not thread-safe; guard concurrent writers with a `Mutex`.
#
# NOTE: To use `BloomFilter`, you must explicitly import it with `require "bloom_filter"`
class BloomFilter
  # The largest supported `hash_count`.
  MAX_HASHES = 32

  # The largest supported `bit_size`: 2^37 bits (16 GiB).
  MAX_BITS = 1_i64 << 37

  # The first bytes of `to_bytes`.
  MAGIC = "CRBF"

  # The version of the `to_bytes` layout.
  FORMAT_VERSION = 1_u8

  private HEADER_SIZE = 28

  # The number of bits in the filter.
  getter bit_size : Int64

  # The number of bits each item sets (and each lookup tests).
  getter hash_count : Int32

  # The seed of the item hash. Filters only combine with filters of the
  # same seed.
  getter seed : UInt64

  @words : Slice(UInt64)
  @premixed : UInt64

  # Creates a filter sized for *capacity* items at the given
  # *false_positive_rate*, using the standard optimum: `bit_size` is
  # `-capacity * ln(rate) / ln(2)²` and `hash_count` is
  # `bit_size / capacity * ln(2)`, rounded.
  #
  # ```
  # filter = BloomFilter.new(1_000_000, false_positive_rate: 0.01)
  # filter.bit_size   # => 9585059
  # filter.hash_count # => 7
  # ```
  #
  # Raises `ArgumentError` unless *capacity* is positive and
  # *false_positive_rate* is strictly between 0 and 1.
  def self.new(capacity : Int, false_positive_rate : Float64 = 0.01, *, seed : UInt64 = 0_u64) : self
    raise ArgumentError.new("Capacity must be positive, not #{capacity}") unless capacity > 0
    unless 0.0 < false_positive_rate < 1.0
      raise ArgumentError.new("False-positive rate must be between 0 and 1 (exclusive), not #{false_positive_rate}")
    end

    ln2 = Math.log(2.0)
    bits = (-capacity.to_f64 * Math.log(false_positive_rate) / (ln2 * ln2)).ceil
    bits = bits.clamp(64.0, MAX_BITS.to_f64)
    hashes = (bits / capacity.to_f64 * ln2).round.clamp(1.0, MAX_HASHES.to_f64)
    new(bits: bits.to_i64, hashes: hashes.to_i32, seed: seed)
  end

  # Creates a filter of exactly *bits* bits that sets *hashes* bits per
  # item. Prefer `new(capacity, false_positive_rate)` unless matching an
  # existing filter's parameters.
  #
  # Raises `ArgumentError` unless *bits* is in `1..MAX_BITS` and *hashes* in
  # `1..MAX_HASHES`.
  def initialize(*, bits : Int, hashes : Int, seed : UInt64 = 0_u64)
    unless 0 < bits <= MAX_BITS
      raise ArgumentError.new("Bit size must be in 1..#{MAX_BITS}, not #{bits}")
    end
    unless 0 < hashes <= MAX_HASHES
      raise ArgumentError.new("Hash count must be in 1..#{MAX_HASHES}, not #{hashes}")
    end
    @bit_size = bits.to_i64
    @hash_count = hashes.to_i32
    @seed = seed
    @premixed = Rapidhash.premix(seed)
    @words = Slice(UInt64).new(((@bit_size + 63) // 64).to_i32)
  end

  protected def initialize(@bit_size : Int64, @hash_count : Int32, @seed : UInt64, @words : Slice(UInt64))
    @premixed = Rapidhash.premix(@seed)
  end

  # Adds *item* to the filter and returns `self`.
  #
  # ```
  # filter = BloomFilter.new(100)
  # filter.add("a").add("b")
  # filter.includes?("b") # => true
  # ```
  def add(item) : self
    each_bit(item) do |word, mask|
      @words.to_unsafe[word] |= mask
    end
    self
  end

  # Adds *item* to the filter and returns `self`.
  def <<(item) : self
    add(item)
  end

  # Adds *item* and returns `true` if the filter changed, which proves the
  # item was not in it before. A `false` answer means the item was probably
  # already present (or is a false positive).
  #
  # ```
  # filter = BloomFilter.new(100)
  # filter.add?("a") # => true
  # filter.add?("a") # => false
  # ```
  def add?(item) : Bool
    changed = 0_u64
    each_bit(item) do |word, mask|
      ptr = @words.to_unsafe + word
      changed |= mask & ~ptr.value
      ptr.value |= mask
    end
    changed != 0
  end

  # Returns `false` if *item* was certainly never added, and `true` if it
  # probably was (wrong with about `false_positive_rate` probability).
  def includes?(item) : Bool
    each_bit(item) do |word, mask|
      return false if @words.to_unsafe[word] & mask == 0
    end
    true
  end

  # Returns `true` if no item has been added since creation or `clear`.
  def empty? : Bool
    @words.all?(&.zero?)
  end

  # Removes every item.
  def clear : self
    @words.fill(0_u64)
    self
  end

  # Estimates the number of distinct items added, from the share of set
  # bits (Swamidass & Baldi). The estimate is good while the filter is
  # within its capacity and degrades as it saturates; a full filter returns
  # `Int64::MAX`.
  #
  # ```
  # filter = BloomFilter.new(1000)
  # 100.times { |i| filter << i }
  # filter.estimated_size # => 100 (approximately)
  # ```
  def estimated_size : Int64
    ones = set_bits
    return Int64::MAX if ones >= @bit_size
    m = @bit_size.to_f64
    estimate = -m / @hash_count * Math.log(1.0 - ones / m)
    estimate.round.to_i64
  end

  # Returns the probability that `includes?` answers `true` for an item
  # that was never added, given the bits set so far: `(set bits /
  # bit_size) ** hash_count`.
  def false_positive_rate : Float64
    (set_bits.to_f64 / @bit_size) ** @hash_count
  end

  # Adds every item of *other* to `self` (a set union). The result equals a
  # filter that saw the items of both.
  #
  # Raises `ArgumentError` unless both filters have the same `bit_size`,
  # `hash_count` and `seed`.
  def merge!(other : BloomFilter) : self
    check_compatible(other)
    @words.size.times do |i|
      @words.to_unsafe[i] |= other.@words.to_unsafe[i]
    end
    self
  end

  # Returns a new filter with the items of both `self` and *other*.
  #
  # Raises `ArgumentError` unless both filters have the same `bit_size`,
  # `hash_count` and `seed`.
  def |(other : BloomFilter) : BloomFilter
    dup.merge!(other)
  end

  # Returns `true` if both filters have the same parameters and bits.
  def ==(other : BloomFilter) : Bool
    @bit_size == other.bit_size && @hash_count == other.hash_count &&
      @seed == other.seed && @words == other.@words
  end

  # Returns a copy that can be changed independently of `self`.
  def dup : BloomFilter
    BloomFilter.new(@bit_size, @hash_count, @seed, @words.dup)
  end

  # :ditto:
  def clone : BloomFilter
    dup
  end

  # Returns the filter serialized in a stable, versioned binary layout that
  # `from_bytes` reads back, here or in any other process:
  #
  # | Offset | Size  | Field                                                  |
  # |--------|-------|--------------------------------------------------------|
  # | 0      | 4     | magic `"CRBF"`                                         |
  # | 4      | 1     | layout version (`1`)                                   |
  # | 5      | 1     | algorithm (`1`: rapidhash V3, enhanced double hashing) |
  # | 6      | 2     | reserved, zero                                         |
  # | 8      | 4     | `hash_count`                                           |
  # | 12     | 8     | `bit_size`                                             |
  # | 20     | 8     | `seed`                                                 |
  # | 28     | 8 × n | the bits as `n = ceil(bit_size / 64)` words            |
  #
  # Integers are little-endian; bit `i` is bit `i % 64` of word `i // 64`.
  def to_bytes : Bytes
    io = IO::Memory.new(HEADER_SIZE + @words.bytesize)
    to_io(io)
    io.to_slice
  end

  # Writes `to_bytes` to *io*.
  def to_io(io : IO) : Nil
    io.write(MAGIC.to_slice)
    io.write_byte(FORMAT_VERSION)
    io.write_byte(1_u8)
    io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)
    io.write_bytes(@hash_count.to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(@bit_size.to_u64, IO::ByteFormat::LittleEndian)
    io.write_bytes(@seed, IO::ByteFormat::LittleEndian)
    # Crystal targets are little-endian, so the words are already in order.
    io.write(@words.to_unsafe_bytes)
  end

  # Reads a filter written by `to_bytes`.
  #
  # Raises `ArgumentError` if *bytes* is not a valid filter.
  def self.from_bytes(bytes : Bytes) : BloomFilter
    io = IO::Memory.new(bytes, writable: false)
    hashes, bits, seed = read_header(io)
    # Checked before allocating, so a corrupt header cannot request a huge
    # buffer.
    unless bytes.size.to_u64 == HEADER_SIZE.to_u64 + (bits + 63) // 64 * 8
      raise ArgumentError.new("Invalid BloomFilter: #{bytes.size} bytes for #{bits} bits")
    end
    read_words(io, hashes, bits, seed)
  rescue IO::EOFError
    raise ArgumentError.new("Invalid BloomFilter: truncated")
  end

  # Reads a filter written by `to_io`.
  #
  # Raises `ArgumentError` if the data is not a valid filter, and
  # `IO::EOFError` if *io* ends early.
  def self.from_io(io : IO) : BloomFilter
    hashes, bits, seed = read_header(io)
    read_words(io, hashes, bits, seed)
  end

  private def self.read_header(io : IO) : {UInt32, UInt64, UInt64}
    magic = Bytes.new(4)
    io.read_fully(magic)
    raise ArgumentError.new("Invalid BloomFilter: bad magic") unless magic == MAGIC.to_slice
    version = io.read_byte || raise IO::EOFError.new
    raise ArgumentError.new("Unsupported BloomFilter version #{version}") unless version == FORMAT_VERSION
    algorithm = io.read_byte || raise IO::EOFError.new
    raise ArgumentError.new("Unsupported BloomFilter algorithm #{algorithm}") unless algorithm == 1
    io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
    hashes = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
    bits = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
    seed = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
    unless 0 < hashes <= MAX_HASHES && 0 < bits <= MAX_BITS
      raise ArgumentError.new("Invalid BloomFilter: #{bits} bits, #{hashes} hashes")
    end
    {hashes, bits, seed}
  end

  private def self.read_words(io : IO, hashes : UInt32, bits : UInt64, seed : UInt64) : BloomFilter
    words = Slice(UInt64).new(((bits + 63) // 64).to_i32)
    io.read_fully(words.to_unsafe_bytes)
    tail = bits % 64
    if tail != 0 && words[-1] >> tail != 0
      raise ArgumentError.new("Invalid BloomFilter: bits set past bit_size")
    end
    new(bits.to_i64, hashes.to_i32, seed, words)
  end

  def inspect(io : IO) : Nil
    io << "#<BloomFilter bit_size=" << @bit_size << " hash_count=" << @hash_count
    io << " seed=" << @seed << " estimated_size=" << estimated_size << '>'
  end

  # Yields the word index and mask of each of the item's bits. The probe
  # sequence is enhanced double hashing (Dillinger & Manolios) over one
  # 64-bit hash, mapped to `0...bit_size` by a multiply-shift instead of a
  # modulo (Lemire).
  @[AlwaysInline]
  private def each_bit(item, &)
    hash = Rapidhash.of_premixed(item, @premixed)
    a = hash
    b = (hash >> 32) | (hash << 32)
    m = @bit_size.to_u64!
    @hash_count.times do |i|
      bit = ((a.to_u128 &* m) >> 64).to_u64!
      yield bit >> 6, 1_u64 << (bit & 63)
      a &+= b
      b &+= i.to_u64!
    end
  end

  private def set_bits : Int64
    @words.sum(0_i64) { |word| word.popcount.to_i64 }
  end

  private def check_compatible(other : BloomFilter) : Nil
    unless @bit_size == other.bit_size && @hash_count == other.hash_count && @seed == other.seed
      raise ArgumentError.new("Cannot combine BloomFilters with different parameters " \
                              "(#{@bit_size}/#{@hash_count}/#{@seed} vs " \
                              "#{other.bit_size}/#{other.hash_count}/#{other.seed})")
    end
  end
end
