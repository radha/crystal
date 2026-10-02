require "spec"
require "count_min_sketch"

# A Zipf-like stream: item i occurs about 10_000 / (i + 1) times.
private def zipf_stream(&)
  500.times do |i|
    (10_000 // (i + 1)).times { yield "item-#{i}" }
  end
end

describe CountMinSketch do
  describe ".new" do
    it "sizes from epsilon and delta" do
      sketch = CountMinSketch.new(epsilon: 0.001, delta: 0.01)
      sketch.width.should eq(2719)
      sketch.depth.should eq(5)
      sketch.conservative?.should be_false
    end

    it "takes explicit dimensions" do
      sketch = CountMinSketch.new(width: 100, depth: 3, seed: 4_u64, conservative: true)
      sketch.width.should eq(100)
      sketch.depth.should eq(3)
      sketch.seed.should eq(4)
      sketch.conservative?.should be_true
    end

    it "rejects invalid parameters" do
      expect_raises(ArgumentError) { CountMinSketch.new(epsilon: 0.0, delta: 0.1) }
      expect_raises(ArgumentError) { CountMinSketch.new(epsilon: 0.1, delta: 1.0) }
      expect_raises(ArgumentError, "too large") { CountMinSketch.new(epsilon: 1e-9, delta: 0.1) }
      expect_raises(ArgumentError) { CountMinSketch.new(width: 0, depth: 1) }
      expect_raises(ArgumentError) { CountMinSketch.new(width: 1, depth: 65) }
      expect_raises(ArgumentError, "too large") { CountMinSketch.new(width: 1 << 25, depth: 16) }
    end
  end

  it "counts exactly when items do not collide" do
    sketch = CountMinSketch.new(width: 10_000, depth: 4)
    sketch.add("a").should eq(1)
    sketch.add("a", 5).should eq(6)
    sketch << "b" << "b"
    sketch.count("a").should eq(6)
    sketch["b"].should eq(2)
    sketch.count("missing").should eq(0)
    sketch.total.should eq(8)
  end

  it "add with zero changes nothing" do
    sketch = CountMinSketch.new(width: 100, depth: 2)
    sketch.add("a", 0).should eq(0)
    sketch.empty?.should be_true
  end

  it "rejects negative counts" do
    expect_raises(ArgumentError) { CountMinSketch.new(width: 10, depth: 2).add("a", -1) }
  end

  {false, true}.each do |conservative|
    it "never underestimates and respects the error bound (conservative: #{conservative})" do
      sketch = CountMinSketch.new(epsilon: 0.001, delta: 0.01, conservative: conservative)
      truth = Hash(String, UInt64).new(0_u64)
      zipf_stream { |item| sketch.add(item); truth[item] += 1 }

      bound = 0.001 * sketch.total
      violations = truth.count do |item, count|
        estimate = sketch.count(item)
        estimate.should be >= count
        estimate - count > bound
      end
      violations.should be <= truth.size * 0.01
    end
  end

  it "conservative update overestimates less" do
    plain = CountMinSketch.new(width: 200, depth: 4)
    conservative = CountMinSketch.new(width: 200, depth: 4, conservative: true)
    truth = Hash(String, UInt64).new(0_u64)
    zipf_stream do |item|
      plain.add(item)
      conservative.add(item)
      truth[item] += 1
    end
    plain_error = truth.sum { |item, count| plain.count(item) - count }
    conservative_error = truth.sum { |item, count| conservative.count(item) - count }
    conservative_error.should be < plain_error // 2
  end

  it "hashes integers and floats by value" do
    sketch = CountMinSketch.new(width: 1000, depth: 3)
    sketch << 1 << 1_i64 << 1_u8 << 2.5 << 2.5_f32
    sketch.count(1).should eq(3)
    sketch.count(2.5).should eq(2)
  end

  it "saturates instead of overflowing" do
    sketch = CountMinSketch.new(width: 10, depth: 2)
    sketch.add("a", UInt64::MAX - 1)
    sketch.add("a", 5).should eq(UInt64::MAX)
    sketch.total.should eq(UInt64::MAX)

    conservative = CountMinSketch.new(width: 10, depth: 2, conservative: true)
    conservative.add("a", UInt64::MAX)
    conservative.add("a").should eq(UInt64::MAX)
  end

  it "#clear" do
    sketch = CountMinSketch.new(width: 10, depth: 2)
    sketch << "a"
    sketch.empty?.should be_false
    sketch.clear.should be(sketch)
    sketch.empty?.should be_true
    sketch.count("a").should eq(0)
    sketch.total.should eq(0)
  end

  describe "merging" do
    it "equals the sketch of the combined stream" do
      a = CountMinSketch.new(width: 300, depth: 4)
      b = CountMinSketch.new(width: 300, depth: 4)
      both = CountMinSketch.new(width: 300, depth: 4)
      1000.times { |i| a.add(i % 37); both.add(i % 37) }
      1000.times { |i| b.add(i % 53, 2); both.add(i % 53, 2) }
      (a + b).should eq(both)
      a.merge!(b).should be(a)
      a.should eq(both)
      a.total.should eq(3000)
    end

    it "rejects different parameters" do
      a = CountMinSketch.new(width: 10, depth: 2)
      expect_raises(ArgumentError, "different parameters") { a + CountMinSketch.new(width: 11, depth: 2) }
      expect_raises(ArgumentError) { a.merge!(CountMinSketch.new(width: 10, depth: 3)) }
      expect_raises(ArgumentError) { a.merge!(CountMinSketch.new(width: 10, depth: 2, seed: 1_u64)) }
    end
  end

  it "#dup is independent" do
    a = CountMinSketch.new(width: 10, depth: 2)
    a << "x"
    b = a.dup
    b << "x"
    a.count("x").should eq(1)
    b.count("x").should eq(2)
    a.clone.should eq(a)
  end

  describe "serialization" do
    it "round-trips" do
      sketch = CountMinSketch.new(width: 50, depth: 3, seed: 8_u64, conservative: true)
      200.times { |i| sketch.add(i % 17, i) }
      copy = CountMinSketch.from_bytes(sketch.to_bytes)
      copy.should eq(sketch)
      copy.conservative?.should be_true
      17.times { |i| copy.count(i).should eq(sketch.count(i)) }

      io = IO::Memory.new
      sketch.to_io(io)
      io.rewind
      CountMinSketch.from_io(io).should eq(sketch)
    end

    it "writes the documented layout" do
      sketch = CountMinSketch.new(width: 3, depth: 2, seed: 6_u64, conservative: true)
      sketch.add("a", 9)
      bytes = sketch.to_bytes
      bytes.size.should eq(40 + 48)
      bytes[0, 4].should eq("CRCM".to_slice)
      bytes[4].should eq(1)
      bytes[5].should eq(1)
      bytes[6].should eq(1)
      format = IO::ByteFormat::LittleEndian
      format.decode(UInt32, bytes[8, 4]).should eq(3)
      format.decode(UInt32, bytes[12, 4]).should eq(2)
      format.decode(UInt64, bytes[16, 8]).should eq(6)
      format.decode(UInt64, bytes[24, 8]).should eq(9)
    end

    # Pins the algorithm: if this changes, persisted sketches break.
    it "uses the same counters on every platform and release" do
      sketch = CountMinSketch.new(width: 4, depth: 2)
      sketch.add("hello", 1)
      sketch.add(42, 2)
      sketch.add(1.5, 4)
      sketch.to_bytes[40..].hexstring.should eq(
        "01000000000000000400000000000000000000000000000002000000000000000000000000000000000000000000000004000000000000000300000000000000")
    end

    it "rejects invalid data" do
      valid = CountMinSketch.new(width: 3, depth: 2).to_bytes
      expect_raises(ArgumentError, "truncated") { CountMinSketch.from_bytes(valid[0, 50]) }
      expect_raises(ArgumentError, "trailing") { CountMinSketch.from_bytes(valid + Bytes[0]) }

      bad = valid.dup
      bad[3] = 0
      expect_raises(ArgumentError, "magic") { CountMinSketch.from_bytes(bad) }

      bad = valid.dup
      bad[4] = 2
      expect_raises(ArgumentError, "version") { CountMinSketch.from_bytes(bad) }

      bad = valid.dup
      bad[6] = 2
      expect_raises(ArgumentError, "flags") { CountMinSketch.from_bytes(bad) }

      bad = valid.dup
      bad[12] = 0
      expect_raises(ArgumentError, "counters") { CountMinSketch.from_bytes(bad) }

      bad = valid.dup
      IO::ByteFormat::LittleEndian.encode(UInt32::MAX, bad[8, 4])
      expect_raises(ArgumentError, "counters") { CountMinSketch.from_bytes(bad) }
    end
  end

  it "#inspect" do
    CountMinSketch.new(width: 2, depth: 1).inspect.should eq(
      "#<CountMinSketch width=2 depth=1 seed=0 conservative=false total=0>")
  end
end
