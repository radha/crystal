require "spec"
require "disjoint_set"

# Brute-force reference: a label per element, relabeling on union.
private class NaivePartition(T)
  getter labels = {} of T => Int32
  @next = 0

  def union(a : T, b : T) : Bool
    add(a)
    add(b)
    from, to = @labels[b], @labels[a]
    return false if from == to
    @labels.each { |k, v| @labels[k] = to if v == from }
    true
  end

  def add(x : T) : Nil
    @labels[x] = (@next += 1) unless @labels.has_key?(x)
  end

  def same?(a : T, b : T) : Bool
    return a == b unless @labels.has_key?(a) && @labels.has_key?(b)
    @labels[a] == @labels[b]
  end

  def set_count : Int32
    @labels.values.uniq.size
  end

  def set_size(x : T) : Int32
    @labels.count { |_, v| v == @labels[x] }
  end
end

describe DisjointSet do
  describe "with arbitrary elements" do
    it "merges sets" do
      set = DisjointSet(String).new
      set.union("alice", "bob").should be_true
      set.union("carol", "dave").should be_true
      set.same?("alice", "bob").should be_true
      set.same?("alice", "carol").should be_false
      set.union("bob", "carol").should be_true
      set.union("dave", "alice").should be_false
      set.set_size("dave").should eq(4)
      set.set_count.should eq(1)
      set.size.should eq(4)
    end

    it "#find returns a common representative" do
      set = DisjointSet(String).new
      set.union("a", "b")
      set.union("b", "c")
      set << "d"
      set.find("a").should eq(set.find("c"))
      %w[a b c].should contain(set.find("b"))
      set.find("d").should eq("d")
      set.find?("zzz").should be_nil
      expect_raises(KeyError, %(Missing disjoint set element: "zzz")) { set.find("zzz") }
    end

    it "#add, #includes? and .new(elements)" do
      set = DisjointSet.new(%w[x y x])
      set.size.should eq(2)
      set.set_count.should eq(2)
      set.add("y").should be_false
      set.add("z").should be_true
      set.includes?("z").should be_true
      set.includes?("w").should be_false
      set.to_a.should eq(%w[x y z])
    end

    it "#same? on absent elements" do
      set = DisjointSet(String).new
      set << "a"
      set.same?("a", "b").should be_false
      set.same?("b", "b").should be_true
      set.includes?("b").should be_false
    end

    it "#sets, #set_of and #each_set" do
      set = DisjointSet.new(%w[a b c d e])
      set.union("d", "a")
      set.union("e", "c")
      set.sets.should eq([%w[a d], %w[b], %w[c e]])
      set.set_of("e").should eq(%w[c e])
      groups = [] of Array(String)
      set.each_set { |group| groups << group }
      groups.should eq(set.sets)
      expect_raises(KeyError) { set.set_of("q") }
      expect_raises(KeyError) { set.set_size("q") }
    end

    it "handles falsy and nilable elements" do
      set = DisjointSet(Bool?).new
      set.union(false, nil)
      set << true
      [false, nil].should contain(set.find(false))
      set.same?(nil, false).should be_true
      set.same?(true, false).should be_false
    end

    it "#clear, #dup, #== and #inspect" do
      set = DisjointSet.new(%w[a b c])
      set.union("a", "c")
      set.inspect.should eq(%(DisjointSet({"a", "c"}, {"b"})))
      copy = set.dup
      copy.should eq(set)
      copy.union("a", "b")
      set.same?("a", "b").should be_false
      copy.should_not eq(set)
      set.clear.should be(set)
      set.empty?.should be_true
      set.set_count.should eq(0)
      set.includes?("a").should be_false
    end

    it "supports break out of iteration" do
      set = DisjointSet.new(%w[a b c])
      seen = [] of String
      set.each { |e| seen << e; break if e == "b" }
      seen.should eq(%w[a b])
      set.each_set { |group| break }
      set.size.should eq(3)
    end
  end

  describe "DisjointSet(Int32) (dense indices)" do
    it "creates singletons 0...size" do
      set = DisjointSet(Int32).new(5)
      set.size.should eq(5)
      set.set_count.should eq(5)
      set.to_a.should eq([0, 1, 2, 3, 4])
      set.union(0, 1)
      set.union(3, 4)
      set.set_count.should eq(3)
      set.sets.should eq([[0, 1], [2], [3, 4]])
    end

    it "grows the range for larger indices" do
      set = DisjointSet(Int32).new
      set.union(9, 2).should be_true
      set.size.should eq(10)
      set.set_count.should eq(9)
      set.add(12).should be_true
      set.add(5).should be_false
      set.size.should eq(13)
      set.find?(20).should be_nil
      set.same?(20, 20).should be_true
      expect_raises(KeyError) { set.find(13) }
    end

    it "rejects negative elements" do
      set = DisjointSet(Int32).new(3)
      expect_raises(ArgumentError, "Negative") { set.union(-1, 0) }
      expect_raises(ArgumentError, "Negative") { set.add(-2) }
      expect_raises(ArgumentError, "Negative") { DisjointSet(Int32).new(-1) }
      set.find?(-1).should be_nil
      set.same?(-1, 0).should be_false
    end

    it "uses no hash table" do
      set = DisjointSet(Int32).new(100)
      99.times { |i| set.union(i, i + 1) }
      set.@index.empty?.should be_true
      set.@elements.empty?.should be_true
      set.set_size(57).should eq(100)
    end

    it "keeps deep chains shallow" do
      n = 200_000
      set = DisjointSet(Int32).new(n)
      (n - 1).times { |i| set.union(i + 1, i) }
      set.set_count.should eq(1)
      set.same?(0, n - 1).should be_true
    end
  end

  it "Int64 elements use the hash table (sparse)" do
    set = DisjointSet(Int64).new
    set.union(1_000_000_000_000, 5)
    set.size.should eq(2)
    set.same?(5_i64, 1_000_000_000_000).should be_true
  end

  it "agrees with a brute-force partition" do
    random = Random.new(42)
    {DisjointSet(Int32).new, DisjointSet(Int32).new(60)}.each do |set|
      naive = NaivePartition(Int32).new
      set.each { |i| naive.add(i) }
      3000.times do
        a, b = random.rand(60), random.rand(60)
        case random.rand(4)
        when 0, 1 then set.union(a, b).should eq(naive.union(a, b))
        when 2    then set.same?(a, b).should eq(naive.same?(a, b))
        else
          if set.includes?(a)
            naive.add(a)
            set.set_size(a).should eq(naive.set_size(a))
          end
        end
      end
      naive.labels.each_key { |i| set.add(i) }
      set.set_count.should eq(naive.set_count + (set.size - naive.labels.size))
    end

    strings = DisjointSet(String).new
    naive = NaivePartition(String).new
    2000.times do
      a, b = "k#{random.rand(80)}", "k#{random.rand(80)}"
      if random.rand(3) == 0
        strings.same?(a, b).should eq(naive.same?(a, b))
      else
        strings.union(a, b).should eq(naive.union(a, b))
      end
    end
    strings.set_count.should eq(naive.set_count)
  end
end
