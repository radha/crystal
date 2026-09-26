require "spec"
require "sorted_map"

# Orders strings by length, then alphabetically: keys equal under `<=>`
# are the same key even when `==` would disagree.
private record ByLength, name : String do
  include Comparable(ByLength)

  def <=>(other : ByLength)
    {name.size, name.downcase} <=> {other.name.size, other.name.downcase}
  end
end

# Keys large enough to force many levels.
private def squares(n)
  SortedMap.from_sorted((0...n).map { |i| {i * 2, i * i} })
end

# A deterministic reference check: random operations mirrored on a Hash.
private def mirror_check(seed, ops, span)
  rng = Random.new(seed)
  map = SortedMap(Int32, Int32).new
  ref = {} of Int32 => Int32
  ops.times do
    key = rng.rand(span)
    case rng.rand(10)
    when 0..4
      map[key] = key * 3
      ref[key] = key * 3
    when 5..7
      map.delete(key).should eq(ref.delete(key))
    when 8
      entry = map.shift?
      if min = ref.keys.min?
        entry.should eq({min, ref.delete(min)})
      else
        entry.should be_nil
      end
    else
      entry = map.pop?
      if max = ref.keys.max?
        entry.should eq({max, ref.delete(max)})
      else
        entry.should be_nil
      end
    end
  end
  map.check_invariants
  map.to_a.should eq(ref.to_a.sort)
end

describe SortedMap do
  describe ".new" do
    it "creates an empty map" do
      map = SortedMap(Int32, String).new
      map.size.should eq(0)
      map.empty?.should be_true
      map.first?.should be_nil
      map.to_a.should be_empty
      map.check_invariants
    end

    it "builds from an unsorted Enumerable, last duplicate winning" do
      map = SortedMap.new([{3, "c"}, {1, "a"}, {2, "b"}, {1, "z"}])
      map.to_a.should eq([{1, "z"}, {2, "b"}, {3, "c"}])
      map.check_invariants
    end

    it "builds from a Hash" do
      map = SortedMap.new({"b" => 2, "a" => 1})
      map.keys.should eq(["a", "b"])
    end

    it "supports the hash-like literal" do
      map = SortedMap{2 => "b", 1 => "a"}
      map.should be_a(SortedMap(Int32, String))
      map.to_a.should eq([{1, "a"}, {2, "b"}])
    end
  end

  describe ".from_sorted" do
    it "builds balanced trees of every small size" do
      (0..400).each do |n|
        map = squares(n)
        map.check_invariants
        map.size.should eq(n)
        map.keys.should eq((0...n).map { |i| i * 2 })
      end
    end

    it "builds a large tree" do
      map = SortedMap.from_sorted((0...100_000).map { |i| {i * 2, i} })
      map.check_invariants
      map[199_998]?.should eq(99_999)
      map[199_999]?.should be_nil
    end

    it "keeps the last of adjacent duplicates" do
      map = SortedMap.from_sorted([{1, "a"}, {1, "b"}, {2, "c"}])
      map.to_a.should eq([{1, "b"}, {2, "c"}])
    end

    it "rejects descending keys" do
      expect_raises(ArgumentError, "Keys are not in ascending order") do
        SortedMap.from_sorted([{2, "b"}, {1, "a"}])
      end
    end

    it "gives a tree that stays valid under inserts and deletes" do
      map = squares(1000)
      (0...1000).each { |i| map[i * 2 + 1] = -i }
      map.check_invariants
      (0...2000).step(3).each { |i| map.delete(i) }
      map.check_invariants
      map.size.should eq(2000 - (0...2000).step(3).size)
    end
  end

  describe "#[]=" do
    it "inserts and replaces" do
      map = SortedMap(String, Int32).new
      (map["b"] = 1).should eq(1)
      map["a"] = 2
      map["b"] = 3
      map.size.should eq(2)
      map.to_a.should eq([{"a", 2}, {"b", 3}])
    end

    it "keeps order through many splits, ascending and descending" do
      up = SortedMap(Int32, Int32).new
      down = SortedMap(Int32, Int32).new
      5000.times do |i|
        up[i] = i
        down[5000 - i] = i
      end
      up.check_invariants
      down.check_invariants
      up.keys.should eq((0...5000).to_a)
      down.keys.should eq((1..5000).to_a)
    end

    it "treats keys equal under <=> as the same key" do
      map = SortedMap(ByLength, Int32).new
      map[ByLength.new("abc")] = 1
      map[ByLength.new("ABC")] = 2
      map.size.should eq(1)
      map[ByLength.new("aBc")].should eq(2)
    end

    it "raises when keys don't compare" do
      map = SortedMap(Float64, Int32).new
      map[1.0] = 1
      expect_raises(ArgumentError, "Comparison of NaN and 1.0 failed") do
        map[Float64::NAN] = 2
      end
    end
  end

  describe "lookups" do
    it "#[] and #[]?" do
      map = squares(100)
      map[10].should eq(25)
      map[11]?.should be_nil
      expect_raises(KeyError, "Missing sorted map key: 11") { map[11] }
    end

    it "#fetch" do
      map = SortedMap{1 => "a"}
      map.fetch(1, "x").should eq("a")
      map.fetch(2, "x").should eq("x")
      map.fetch(3) { |key| "no #{key}" }.should eq("no 3")
    end

    it "#has_key? and #has_value?" do
      map = SortedMap{1 => "a"}
      map.has_key?(1).should be_true
      map.has_key?(2).should be_false
      map.has_value?("a").should be_true
      map.has_value?("b").should be_false
    end

    it "#put_if_absent" do
      map = SortedMap{1 => "a"}
      map.put_if_absent(1, "z").should eq("a")
      map.put_if_absent(2) { |key| "v#{key}" }.should eq("v2")
      map.to_a.should eq([{1, "a"}, {2, "v2"}])
    end
  end

  describe "#delete" do
    it "returns the value or nil" do
      map = SortedMap{1 => "a", 2 => "b"}
      map.delete(1).should eq("a")
      map.delete(1).should be_nil
      map.delete(5) { |key| "no #{key}" }.should eq("no 5")
      map.to_a.should eq([{2, "b"}])
    end

    it "drains a large tree in random order" do
      map = squares(5000)
      keys = map.keys.shuffle(Random.new(7))
      keys.each_with_index do |key, i|
        map.delete(key).should eq((key // 2) ** 2)
        map.check_invariants if i % 500 == 0
      end
      map.empty?.should be_true
      map.check_invariants
    end

    it "matches a Hash under random operations" do
      mirror_check(1, 20_000, 50)
      mirror_check(2, 20_000, 2_000)
      mirror_check(3, 50_000, 20_000)
    end
  end

  describe "#delete_range" do
    it "removes a closed, exclusive or open range" do
      map = SortedMap.new((1..10).map { |i| {i, i} })
      map.delete_range(3..5).should eq(3)
      map.delete_range(8...10).should eq(2)
      map.keys.should eq([1, 2, 6, 7, 10])
      map.delete_range(..6).should eq(3)
      map.delete_range(7..).should eq(2)
      map.empty?.should be_true
    end

    it "cuts large ranges out of large trees" do
      map = squares(20_000) # keys 0, 2, ..., 39998
      map.delete_range(1000..30_000).should eq(14_501)
      map.check_invariants
      map.keys.should eq((0...500).map { |i| i * 2 } + (15_001...20_000).map { |i| i * 2 })
      map.delete_range(...900).should eq(450)
      map.check_invariants
      map.delete_range(35_000..).should eq(2_500)
      map.check_invariants
      map.first_key.should eq(900)
      map.last_key.should eq(34_998)
      map.delete_range(nil..nil).should eq(2_549)
      map.empty?.should be_true
      map.check_invariants
    end

    it "matches a Hash for random ranges, and the tree stays usable" do
      rng = Random.new(21)
      30.times do |round|
        span = 20_000
        keys = (0...span).to_a.sample(rng.rand(1..8_000), rng)
        map = round.even? ? SortedMap.new(keys.map { |k| {k, k} }) : SortedMap(Int32, Int32).new.tap { |m| keys.each { |k| m[k] = k } }
        ref = keys.to_set
        8.times do
          low = rng.rand(span)
          high = low + rng.rand(span // 2)
          range = rng.rand(2) == 0 ? (low..high) : (low...high)
          map.delete_range(range).should eq(ref.count { |k| range.includes?(k) })
          ref.reject! { |k| range.includes?(k) }
          map.check_invariants
          50.times do
            k = rng.rand(span)
            map[k] = k
            ref << k
          end
          map.check_invariants
          map.keys.should eq(ref.to_a.sort)
        end
      end
    end
  end

  describe "ends" do
    it "#first, #last and their key forms" do
      map = squares(1000)
      map.first.should eq({0, 0})
      map.last.should eq({1998, 999 * 999})
      map.first_key.should eq(0)
      map.last_key?.should eq(1998)
    end

    it "raises or returns nil when empty" do
      map = SortedMap(Int32, Int32).new
      expect_raises(Enumerable::EmptyError) { map.first }
      expect_raises(Enumerable::EmptyError) { map.last_key }
      expect_raises(Enumerable::EmptyError) { map.shift }
      expect_raises(Enumerable::EmptyError) { map.pop }
      map.first_key?.should be_nil
      map.shift?.should be_nil
      map.pop?.should be_nil
    end

    it "#shift and #pop drain in order" do
      map = squares(700)
      shifted = [] of Int32
      popped = [] of Int32
      while entry = map.shift?
        shifted << entry[0]
        popped << map.pop[0] unless map.empty?
      end
      shifted.should eq((0...350).map { |i| i * 2 })
      popped.should eq((350...700).map { |i| i * 2 }.reverse)
      map.check_invariants
    end
  end

  describe "navigation" do
    map = squares(1000) # keys 0, 2, ..., 1998

    it "#floor and #ceiling" do
      map.floor(10).should eq({10, 25})
      map.floor(11).should eq({10, 25})
      map.floor(-1).should be_nil
      map.floor(5000).should eq({1998, 999 * 999})
      map.ceiling(11).should eq({12, 36})
      map.ceiling(12).should eq({12, 36})
      map.ceiling(1999).should be_nil
      map.ceiling(-5).should eq({0, 0})
    end

    it "#lower and #higher are strict" do
      map.lower(10).should eq({8, 16})
      map.lower(0).should be_nil
      map.higher(10).should eq({12, 36})
      map.higher(1998).should be_nil
    end

    it "key forms" do
      map.floor_key(11).should eq(10)
      map.ceiling_key(11).should eq(12)
      map.lower_key(11).should eq(10)
      map.higher_key(11).should eq(12)
      map.higher_key(3000).should be_nil
    end

    it "agrees with a linear scan at every probe" do
      keys = map.keys
      (-2..2001).each do |probe|
        map.floor_key(probe).should eq(keys.reverse.find { |k| k <= probe })
        map.ceiling_key(probe).should eq(keys.find { |k| k >= probe })
        map.lower_key(probe).should eq(keys.reverse.find { |k| k < probe })
        map.higher_key(probe).should eq(keys.find { |k| k > probe })
      end
    end

    it "works on an empty map" do
      empty = SortedMap(Int32, Int32).new
      empty.floor(1).should be_nil
      empty.ceiling(1).should be_nil
    end
  end

  describe "iteration" do
    it "#each yields in order, block and iterator" do
      map = SortedMap{3 => "c", 1 => "a", 2 => "b"}
      seen = [] of {Int32, String}
      map.each { |key, value| seen << {key, value} }
      seen.should eq([{1, "a"}, {2, "b"}, {3, "c"}])
      map.each.to_a.should eq(seen)
    end

    it "#reverse_each yields in descending order" do
      map = squares(500)
      expected = (0...500).map { |i| {i * 2, i * i} }.reverse
      seen = [] of {Int32, Int32}
      map.reverse_each { |entry| seen << entry }
      seen.should eq(expected)
      map.reverse_each.to_a.should eq(expected)
    end

    it "#each_key, #each_value, #keys and #values" do
      map = SortedMap{2 => "b", 1 => "a"}
      map.each_key.to_a.should eq([1, 2])
      map.each_value.to_a.should eq(["a", "b"])
      map.keys.should eq([1, 2])
      map.values.should eq(["a", "b"])
    end

    it "includes Enumerable" do
      map = SortedMap{1 => 10, 2 => 20, 3 => 30}
      map.sum { |_, value| value }.should eq(60)
      map.select { |key, _| key.odd? }.should eq([{1, 10}, {3, 30}])
      map.to_h.should eq({1 => 10, 2 => 20, 3 => 30})
    end

    it "stays memory safe when changed during iteration" do
      rng = Random.new(3)
      map = SortedMap.new((0...2000).map { |i| {i.to_s, i.to_s} })
      iter = map.each
      map.each do |key, value|
        value.should eq(key)
        map.delete(rng.rand(2000).to_s)
        fresh = rng.rand(2000).to_s
        map[fresh] = fresh if rng.rand(4) == 0
        if entry = iter.next.as?({String, String})
          entry[0].should be_a(String)
        end
      end
      map.check_invariants
    end
  end

  describe "range iteration" do
    map = squares(1000) # keys 0, 2, ..., 1998

    it "yields keys within closed, exclusive and open ranges" do
      map.each(10..16).map(&.[0]).to_a.should eq([10, 12, 14, 16])
      map.each(10...16).map(&.[0]).to_a.should eq([10, 12, 14])
      map.each(11..15).map(&.[0]).to_a.should eq([12, 14])
      map.each(1990..).map(&.[0]).to_a.should eq([1990, 1992, 1994, 1996, 1998])
      map.each(..4).map(&.[0]).to_a.should eq([0, 2, 4])
      map.each(...4).map(&.[0]).to_a.should eq([0, 2])
      map.each(3000..4000).to_a.should be_empty
      map.each(10..5).to_a.should be_empty
    end

    it "block form agrees with the iterator" do
      seen = [] of Int32
      map.each(100..140) { |key, _| seen << key }
      seen.should eq(map.each(100..140).map(&.[0]).to_a)
    end

    it "#reverse_each over a range" do
      map.reverse_each(10..16).map(&.[0]).to_a.should eq([16, 14, 12, 10])
      map.reverse_each(10...16).map(&.[0]).to_a.should eq([14, 12, 10])
      map.reverse_each(...5).map(&.[0]).to_a.should eq([4, 2, 0])
      map.reverse_each(1995..).map(&.[0]).to_a.should eq([1998, 1996])
      seen = [] of Int32
      map.reverse_each(11..17) { |key, _| seen << key }
      seen.should eq([16, 14, 12])
    end

    it "agrees with filtering every key, for many ranges" do
      keys = map.keys
      rng = Random.new(11)
      300.times do
        low = rng.rand(-10..2010)
        high = low + rng.rand(-5..300)
        {low..high, low...high, (low..), (..high), (...high)}.each do |range|
          expected = keys.select { |key| range.includes?(key) }
          map.each(range).map(&.[0]).to_a.should eq(expected)
          map.reverse_each(range).map(&.[0]).to_a.should eq(expected.reverse)
        end
      end
    end
  end

  describe "copies and equality" do
    it "#dup makes an independent copy" do
      map = squares(300)
      copy = map.dup
      copy.check_invariants
      copy.should eq(map)
      copy[1] = 1
      map.has_key?(1).should be_false
    end

    it "#clone clones values" do
      map = SortedMap{1 => [1]}
      copy = map.clone
      copy[1] << 2
      map[1].should eq([1])
    end

    it "#== and #hash" do
      a = SortedMap{1 => "a", 2 => "b"}
      b = SortedMap.new([{2, "b"}, {1, "a"}])
      a.should eq(b)
      a.hash.should eq(b.hash)
      b[3] = "c"
      a.should_not eq(b)
      b.delete(3)
      b[2] = "x"
      a.should_not eq(b)
    end

    it "#clear" do
      map = squares(100)
      map.clear.empty?.should be_true
      map[1] = 1
      map.to_a.should eq([{1, 1}])
    end
  end

  describe "#to_s and #inspect" do
    it "prints like a hash" do
      SortedMap{2 => "b", 1 => "a"}.to_s.should eq(%(SortedMap{1 => "a", 2 => "b"}))
      SortedMap(Int32, Int32).new.inspect.should eq("SortedMap{}")
    end
  end
end
