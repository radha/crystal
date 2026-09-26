require "spec"
require "sorted_set"

describe SortedSet do
  describe ".new" do
    it "creates an empty set" do
      set = SortedSet(Int32).new
      set.empty?.should be_true
      set.first?.should be_nil
    end

    it "builds from an unsorted Enumerable, dropping duplicates" do
      set = SortedSet.new([5, 1, 3, 1, 5])
      set.to_a.should eq([1, 3, 5])
      set.check_invariants
    end

    it "supports the array-like literal" do
      set = SortedSet{"b", "a"}
      set.should be_a(SortedSet(String))
      set.to_a.should eq(["a", "b"])
    end

    it ".from_sorted rejects descending input" do
      SortedSet.from_sorted([1, 1, 2]).to_a.should eq([1, 2])
      expect_raises(ArgumentError) { SortedSet.from_sorted([2, 1]) }
    end
  end

  describe "adding and removing" do
    it "#add, #<<, #add? and #concat" do
      set = SortedSet(Int32).new
      set << 3 << 1
      set.add(2).should be(set)
      set.add?(4).should be_true
      set.add?(4).should be_false
      set.concat([0, 9])
      set.to_a.should eq([0, 1, 2, 3, 4, 9])
    end

    it "#delete and #includes?" do
      set = SortedSet{1, 2, 3}
      set.includes?(2).should be_true
      set.delete(2).should be_true
      set.delete(2).should be_false
      set.includes?(2).should be_false
    end

    it "#delete_range" do
      set = SortedSet.new(1..10)
      set.delete_range(4..6).should eq(3)
      set.to_a.should eq([1, 2, 3, 7, 8, 9, 10])
    end

    it "#shift, #pop and the ends" do
      set = SortedSet{2, 3, 1}
      set.first.should eq(1)
      set.last.should eq(3)
      set.shift.should eq(1)
      set.pop.should eq(3)
      set.pop?.should eq(2)
      set.pop?.should be_nil
      expect_raises(Enumerable::EmptyError) { set.shift }
    end
  end

  describe "navigation" do
    set = SortedSet{10, 20, 30}

    it "#floor, #ceiling, #lower and #higher" do
      set.floor(25).should eq(20)
      set.floor(20).should eq(20)
      set.floor(5).should be_nil
      set.ceiling(25).should eq(30)
      set.ceiling(31).should be_nil
      set.lower(20).should eq(10)
      set.higher(20).should eq(30)
      set.higher(30).should be_nil
    end
  end

  describe "iteration" do
    set = SortedSet.new((1..20).to_a.reverse)

    it "iterates in order both ways" do
      set.each.to_a.should eq((1..20).to_a)
      set.reverse_each.to_a.should eq((1..20).to_a.reverse)
      seen = [] of Int32
      set.each { |x| seen << x }
      seen.should eq((1..20).to_a)
    end

    it "iterates a range both ways" do
      set.each(5...8).to_a.should eq([5, 6, 7])
      set.reverse_each(18..).to_a.should eq([20, 19, 18])
      seen = [] of Int32
      set.each(..3) { |x| seen << x }
      set.reverse_each(3..4) { |x| seen << x }
      seen.should eq([1, 2, 3, 4, 3])
    end
  end

  describe "set algebra" do
    a = SortedSet{1, 2, 3, 4}
    b = SortedSet{3, 4, 5}

    it "|, &, - and ^" do
      (a | b).to_a.should eq([1, 2, 3, 4, 5])
      (a & b).to_a.should eq([3, 4])
      (a - b).to_a.should eq([1, 2])
      (b - a).to_a.should eq([5])
      (a ^ b).to_a.should eq([1, 2, 5])
    end

    it "handles empty operands" do
      empty = SortedSet(Int32).new
      (a | empty).should eq(a)
      (a & empty).empty?.should be_true
      (empty - a).empty?.should be_true
      (empty ^ a).should eq(a)
    end

    it "matches Set on random inputs and builds valid trees" do
      rng = Random.new(5)
      50.times do
        xs = Array.new(rng.rand(2000)) { rng.rand(3000) }
        ys = Array.new(rng.rand(2000)) { rng.rand(3000) }
        sx = SortedSet.new(xs)
        sy = SortedSet.new(ys)
        hx = xs.to_set
        hy = ys.to_set
        {
          {sx | sy, hx | hy},
          {sx & sy, hx & hy},
          {sx - sy, hx - hy},
          {sx ^ sy, hx ^ hy},
        }.each do |sorted, reference|
          sorted.check_invariants
          sorted.to_a.should eq(reference.to_a.sort)
        end
        sx.subset_of?(sy).should eq(hx.subset_of?(hy))
        sx.intersects?(sy).should eq(hx.intersects?(hy))
      end
    end

    it "subset and superset predicates" do
      small = SortedSet{3, 4}
      small.subset_of?(a).should be_true
      small.proper_subset_of?(a).should be_true
      a.subset_of?(a).should be_true
      a.proper_subset_of?(a).should be_false
      a.superset_of?(small).should be_true
      a.proper_superset_of?(small).should be_true
      b.subset_of?(a).should be_false
      a.intersects?(b).should be_true
      a.intersects?(SortedSet{9}).should be_false
    end
  end

  describe "copies, equality and printing" do
    it "#dup, #==, #hash" do
      set = SortedSet{1, 2}
      copy = set.dup
      copy.should eq(set)
      copy.hash.should eq(set.hash)
      copy << 3
      set.should_not eq(copy)
    end

    it "#to_s" do
      SortedSet{"b", "a"}.to_s.should eq(%(SortedSet{"a", "b"}))
      SortedSet(Int32).new.to_s.should eq("SortedSet{}")
    end
  end
end
