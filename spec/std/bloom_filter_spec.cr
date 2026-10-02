require "spec"
require "bloom_filter"

private struct Point
  def initialize(@x : Int32, @y : Int32)
  end

  def rapidhash(seed : UInt64) : UInt64
    Rapidhash.of_premixed("#{@x},#{@y}", seed)
  end
end

describe BloomFilter do
  describe ".new" do
    it "sizes the filter from capacity and false-positive rate" do
      filter = BloomFilter.new(1_000_000, false_positive_rate: 0.01)
      filter.bit_size.should eq(9_585_059)
      filter.hash_count.should eq(7)
      BloomFilter.new(1000, 0.001).hash_count.should eq(10)
    end

    it "keeps tiny filters at least one word" do
      BloomFilter.new(1, 0.5).bit_size.should eq(64)
    end

    it "takes explicit parameters" do
      filter = BloomFilter.new(bits: 1000, hashes: 3, seed: 9_u64)
      filter.bit_size.should eq(1000)
      filter.hash_count.should eq(3)
      filter.seed.should eq(9)
    end

    it "rejects invalid parameters" do
      expect_raises(ArgumentError) { BloomFilter.new(0) }
      expect_raises(ArgumentError) { BloomFilter.new(10, 0.0) }
      expect_raises(ArgumentError) { BloomFilter.new(10, 1.0) }
      expect_raises(ArgumentError) { BloomFilter.new(bits: 0, hashes: 1) }
      expect_raises(ArgumentError) { BloomFilter.new(bits: 64, hashes: 0) }
      expect_raises(ArgumentError) { BloomFilter.new(bits: 64, hashes: 33) }
      expect_raises(ArgumentError) { BloomFilter.new(bits: BloomFilter::MAX_BITS + 1, hashes: 1) }
    end
  end

  it "never reports a false negative" do
    filter = BloomFilter.new(10_000, 0.01)
    10_000.times { |i| filter << "item-#{i}" }
    10_000.times { |i| filter.includes?("item-#{i}").should be_true }
  end

  it "keeps the false-positive rate near the target" do
    filter = BloomFilter.new(10_000, 0.01)
    10_000.times { |i| filter << "in-#{i}" }
    false_positives = (0...100_000).count { |i| filter.includes?("out-#{i}") }
    rate = false_positives / 100_000
    rate.should be < 0.015
    rate.should be > 0.005
    filter.false_positive_rate.should be_close(0.01, 0.003)
  end

  it "hashes integers and floats by value" do
    filter = BloomFilter.new(100)
    filter << 7 << 2.5_f32
    filter.includes?(7_i64).should be_true
    filter.includes?(7_u8).should be_true
    filter.includes?(2.5).should be_true
  end

  it "accepts user types with a rapidhash method" do
    filter = BloomFilter.new(100)
    filter << Point.new(1, 2)
    filter.includes?(Point.new(1, 2)).should be_true
    filter.includes?("1,2").should be_true
  end

  it "treats Bytes and String with the same content alike" do
    filter = BloomFilter.new(100)
    filter << "abc"
    filter.includes?("abc".to_slice).should be_true
  end

  it "#add? reports whether the filter changed" do
    filter = BloomFilter.new(100)
    filter.add?("a").should be_true
    filter.add?("a").should be_false
    filter.includes?("a").should be_true
  end

  it "#empty? and #clear" do
    filter = BloomFilter.new(100)
    filter.empty?.should be_true
    filter << 1
    filter.empty?.should be_false
    filter.clear.should be(filter)
    filter.empty?.should be_true
    filter.includes?(1).should be_false
  end

  it "#estimated_size approximates the distinct count" do
    filter = BloomFilter.new(100_000, 0.01)
    filter.estimated_size.should eq(0)
    20_000.times { |i| filter << i << i }
    filter.estimated_size.should be_close(20_000, 400)
  end

  it "#estimated_size of a saturated filter" do
    filter = BloomFilter.new(bits: 64, hashes: 4)
    10_000.times { |i| filter << i }
    filter.estimated_size.should eq(Int64::MAX)
  end

  it "differs by seed" do
    a = BloomFilter.new(bits: 1024, hashes: 3, seed: 1_u64)
    b = BloomFilter.new(bits: 1024, hashes: 3, seed: 2_u64)
    a << "x"
    b << "x"
    a.to_bytes[28..].should_not eq(b.to_bytes[28..])
  end

  describe "combining" do
    it "#merge! and #| take the union" do
      a = BloomFilter.new(1000, 0.01)
      b = BloomFilter.new(1000, 0.01)
      both = BloomFilter.new(1000, 0.01)
      300.times { |i| a << i; both << i }
      (300...600).each { |i| b << i; both << i }

      union = a | b
      union.should eq(both)
      a.includes?(400).should be_false
      a.merge!(b).should be(a)
      a.should eq(both)
    end

    it "rejects different parameters" do
      a = BloomFilter.new(bits: 128, hashes: 3)
      expect_raises(ArgumentError, "different parameters") { a | BloomFilter.new(bits: 256, hashes: 3) }
      expect_raises(ArgumentError) { a | BloomFilter.new(bits: 128, hashes: 4) }
      expect_raises(ArgumentError) { a.merge!(BloomFilter.new(bits: 128, hashes: 3, seed: 1_u64)) }
    end
  end

  it "#dup is independent" do
    a = BloomFilter.new(100)
    a << 1
    b = a.dup
    b << 2
    a.includes?(1).should be_true
    b.should_not eq(a)
    a.clone.should eq(a)
  end

  describe "serialization" do
    it "round-trips" do
      filter = BloomFilter.new(bits: 1000, hashes: 5, seed: 77_u64)
      100.times { |i| filter << "k#{i}" }
      copy = BloomFilter.from_bytes(filter.to_bytes)
      copy.should eq(filter)
      copy.seed.should eq(77)
      100.times { |i| copy.includes?("k#{i}").should be_true }

      io = IO::Memory.new
      filter.to_io(io)
      io.rewind
      BloomFilter.from_io(io).should eq(filter)
    end

    it "writes the documented layout" do
      filter = BloomFilter.new(bits: 100, hashes: 3, seed: 5_u64)
      bytes = filter.to_bytes
      bytes.size.should eq(28 + 16)
      bytes[0, 4].should eq("CRBF".to_slice)
      bytes[4].should eq(1)
      bytes[5].should eq(1)
      IO::ByteFormat::LittleEndian.decode(UInt32, bytes[8, 4]).should eq(3)
      IO::ByteFormat::LittleEndian.decode(UInt64, bytes[12, 8]).should eq(100)
      IO::ByteFormat::LittleEndian.decode(UInt64, bytes[20, 8]).should eq(5)
    end

    # Pins the algorithm: if this changes, persisted filters break.
    it "sets the same bits on every platform and release" do
      filter = BloomFilter.new(bits: 256, hashes: 4)
      filter << "hello" << 42 << 1.5
      filter.to_bytes[28..].hexstring.should eq(
        "0000000000400000000800000000400000044030000006000001004004000000")
    end

    it "rejects invalid data" do
      valid = BloomFilter.new(bits: 100, hashes: 3).to_bytes
      expect_raises(ArgumentError, "truncated") { BloomFilter.from_bytes(valid[0, 10]) }
      expect_raises(ArgumentError, "bytes for") { BloomFilter.from_bytes(valid[0, valid.size - 1]) }

      bad = valid.dup
      bad[0] = 'X'.ord.to_u8
      expect_raises(ArgumentError, "magic") { BloomFilter.from_bytes(bad) }

      bad = valid.dup
      bad[4] = 2
      expect_raises(ArgumentError, "version") { BloomFilter.from_bytes(bad) }

      bad = valid.dup
      bad[8] = 0
      expect_raises(ArgumentError, "hashes") { BloomFilter.from_bytes(bad) }

      bad = valid.dup
      bad[-1] = 0x80 # bit 127, past bit_size 100
      expect_raises(ArgumentError, "past bit_size") { BloomFilter.from_bytes(bad) }

      # A header claiming a huge filter fails on the size check, not by
      # allocating.
      bad = valid.dup
      IO::ByteFormat::LittleEndian.encode(BloomFilter::MAX_BITS.to_u64, bad[12, 8])
      expect_raises(ArgumentError, "bytes for") { BloomFilter.from_bytes(bad) }
    end
  end

  it "#inspect" do
    BloomFilter.new(bits: 64, hashes: 2).inspect.should eq(
      "#<BloomFilter bit_size=64 hash_count=2 seed=0 estimated_size=0>")
  end
end
