require "spec"
require "hyper_log_log"

describe HyperLogLog do
  describe ".new" do
    it "defaults to precision 14" do
      sketch = HyperLogLog.new
      sketch.precision.should eq(14)
      sketch.seed.should eq(0)
      sketch.to_bytes.size.should eq(16 + 16384)
    end

    it "rejects precision out of range" do
      expect_raises(ArgumentError) { HyperLogLog.new(3) }
      expect_raises(ArgumentError) { HyperLogLog.new(19) }
      HyperLogLog.new(4).precision.should eq(4)
      HyperLogLog.new(18).precision.should eq(18)
    end
  end

  it "counts zero for an empty sketch" do
    HyperLogLog.new.size.should eq(0)
    HyperLogLog.new.empty?.should be_true
  end

  it "counts small sets exactly in practice" do
    sketch = HyperLogLog.new
    sketch << "alice" << "bob" << "alice"
    sketch.size.should eq(2)
    100.times { |i| sketch << "user-#{i}" }
    sketch.size.should eq(102)
  end

  it "ignores duplicates" do
    sketch = HyperLogLog.new
    10.times { 1000.times { |i| sketch << i } }
    sketch.size.should be_close(1000, 10)
  end

  {4, 10, 14, 18}.each do |precision|
    it "stays within a few standard errors at precision #{precision}" do
      sketch = HyperLogLog.new(precision)
      [100, 10_000, 200_000].each do |n|
        sketch.clear
        n.times { |i| sketch << "k#{i}" }
        error = (sketch.size - n).abs / n
        error.should be < 4 * sketch.standard_error + 0.001, file: __FILE__, line: __LINE__
      end
    end
  end

  it "estimates large cardinalities" do
    sketch = HyperLogLog.new(12)
    2_000_000.times { |i| sketch << i }
    (sketch.size - 2_000_000).abs.should be < 2_000_000 * 4 * sketch.standard_error
  end

  it "hashes integers and floats by value" do
    sketch = HyperLogLog.new
    sketch << 1 << 1_i64 << 1_u8 << 1.0 << 1.0_f32
    sketch.size.should eq(2)
  end

  it "#add? reports register changes" do
    sketch = HyperLogLog.new
    sketch.add?("a").should be_true
    sketch.add?("a").should be_false
  end

  it "invalidates the cached size" do
    sketch = HyperLogLog.new
    sketch << 1
    sketch.size.should eq(1)
    sketch << 2
    sketch.size.should eq(2)
    sketch.clear
    sketch.size.should eq(0)
  end

  describe "merging" do
    it "equals the sketch of the combined stream" do
      a = HyperLogLog.new(10)
      b = HyperLogLog.new(10)
      both = HyperLogLog.new(10)
      5000.times { |i| a << i; both << i }
      (2500...9000).each { |i| b << i; both << i }
      union = a | b
      union.should eq(both)
      union.size.should eq(both.size)
      a.size.should be_close(5000, 5000 * 0.15)
      a.merge!(b).should be(a)
      a.should eq(both)
      a.size.should be_close(9000, 9000 * 0.15)
    end

    it "rejects different parameters" do
      expect_raises(ArgumentError, "different parameters") { HyperLogLog.new(10) | HyperLogLog.new(11) }
      expect_raises(ArgumentError) { HyperLogLog.new(10).merge!(HyperLogLog.new(10, seed: 1_u64)) }
    end
  end

  it "#dup is independent" do
    a = HyperLogLog.new(8)
    a << 1
    b = a.dup
    b << 2 << 3 << 4
    a.size.should eq(1)
    b.size.should eq(4)
    a.clone.should eq(a)
  end

  describe "serialization" do
    it "round-trips" do
      sketch = HyperLogLog.new(12, seed: 99_u64)
      10_000.times { |i| sketch << i }
      copy = HyperLogLog.from_bytes(sketch.to_bytes)
      copy.should eq(sketch)
      copy.size.should eq(sketch.size)
      copy.seed.should eq(99)

      io = IO::Memory.new
      sketch.to_io(io)
      io.rewind
      HyperLogLog.from_io(io).should eq(sketch)
    end

    it "writes the documented layout" do
      bytes = HyperLogLog.new(4, seed: 7_u64).to_bytes
      bytes.size.should eq(16 + 16)
      bytes[0, 4].should eq("CRHL".to_slice)
      bytes[4].should eq(1)
      bytes[5].should eq(1)
      bytes[6].should eq(4)
      IO::ByteFormat::LittleEndian.decode(UInt64, bytes[8, 8]).should eq(7)
    end

    # Pins the algorithm: if this changes, persisted sketches break.
    it "sets the same registers on every platform and release" do
      sketch = HyperLogLog.new(4)
      sketch << "hello" << 42 << 1.5 << "world"
      sketch.to_bytes[16..].hexstring.should eq("00000100030000020000000000010000")
    end

    it "rejects invalid data" do
      valid = HyperLogLog.new(4).to_bytes
      expect_raises(ArgumentError, "truncated") { HyperLogLog.from_bytes(valid[0, 20]) }
      expect_raises(ArgumentError, "trailing") { HyperLogLog.from_bytes(valid + Bytes[0]) }

      bad = valid.dup
      bad[1] = 0
      expect_raises(ArgumentError, "magic") { HyperLogLog.from_bytes(bad) }

      bad = valid.dup
      bad[4] = 9
      expect_raises(ArgumentError, "version") { HyperLogLog.from_bytes(bad) }

      bad = valid.dup
      bad[6] = 30
      expect_raises(ArgumentError, "precision") { HyperLogLog.from_bytes(bad) }

      bad = valid.dup
      bad[16] = 62 # max rank at precision 4 is 61
      expect_raises(ArgumentError, "register") { HyperLogLog.from_bytes(bad) }
    end
  end

  it "#inspect" do
    HyperLogLog.new(4).inspect.should eq("#<HyperLogLog precision=4 seed=0 size=0>")
  end
end
