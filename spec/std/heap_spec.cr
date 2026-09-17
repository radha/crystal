require "spec"
require "heap"

private record Task, priority : Int32, name : String

describe Heap do
  describe ".new" do
    it "creates an empty min-heap" do
      heap = Heap(Int32).new
      heap.size.should eq(0)
      heap.empty?.should be_true
      heap.pop?.should be_nil
      heap.peek?.should be_nil
    end

    it "heapifies an array without mutating it" do
      source = [5, 3, 8, 1, 9, 2]
      heap = Heap.new(source)
      source.should eq([5, 3, 8, 1, 9, 2])
      heap.size.should eq(6)
      drain(heap).should eq([1, 2, 3, 5, 8, 9])
    end

    it "heapifies any Enumerable" do
      heap = Heap.new((1..10).each.select(&.odd?))
      drain(heap).should eq([1, 3, 5, 7, 9])
    end

    it "accepts an initial capacity" do
      heap = Heap(Int32).new(16)
      heap.push(1)
      heap.pop.should eq(1)
    end

    it "orders by the comparator block" do
      heap = Heap(Int32).new { |a, b| b <=> a }
      heap.push(3).push(1).push(2)
      drain(heap).should eq([3, 2, 1])
    end

    it "heapifies with a comparator block" do
      heap = Heap.new([3, 1, 2]) { |a, b| b <=> a }
      drain(heap).should eq([3, 2, 1])
    end

    it "works for element types without <=> when given a comparator" do
      heap = Heap(Task).new { |a, b| a.priority <=> b.priority }
      heap << Task.new(2, "b") << Task.new(1, "a") << Task.new(3, "c")
      drain(heap).map(&.name).should eq(%w(a b c))
    end
  end

  describe "#push" do
    it "returns self so pushes chain" do
      heap = Heap(Int32).new
      heap.push(2).push(1).should be(heap)
      heap.size.should eq(2)
    end

    it "keeps duplicates" do
      heap = Heap(Int32).new
      heap << 2 << 1 << 2 << 1
      drain(heap).should eq([1, 1, 2, 2])
    end
  end

  describe "#pop" do
    it "removes and returns the smallest element" do
      heap = Heap.new([4, 2, 9, 7])
      heap.pop.should eq(2)
      heap.pop.should eq(4)
      heap.size.should eq(2)
    end

    it "raises IndexError when empty" do
      expect_raises(IndexError) { Heap(Int32).new.pop }
    end
  end

  describe "#peek" do
    it "returns the smallest element without removing it" do
      heap = Heap.new([4, 2, 9])
      heap.peek.should eq(2)
      heap.size.should eq(3)
    end

    it "raises IndexError when empty" do
      expect_raises(IndexError) { Heap(Int32).new.peek }
    end
  end

  describe "#replace_top" do
    it "returns the top and inserts the new value" do
      heap = Heap.new([1, 5, 3])
      heap.replace_top(4).should eq(1)
      drain(heap).should eq([3, 4, 5])
    end

    it "raises IndexError when empty" do
      expect_raises(IndexError) { Heap(Int32).new.replace_top(1) }
    end
  end

  describe "#push_pop" do
    it "returns the new value when it is smaller than the top" do
      heap = Heap.new([3, 5])
      heap.push_pop(1).should eq(1)
      drain(heap).should eq([3, 5])
    end

    it "returns the old top when the new value is larger" do
      heap = Heap.new([3, 5])
      heap.push_pop(4).should eq(3)
      drain(heap).should eq([4, 5])
    end

    it "returns the value itself when empty" do
      heap = Heap(Int32).new
      heap.push_pop(7).should eq(7)
      heap.empty?.should be_true
    end
  end

  describe "#concat" do
    it "adds every element and returns self" do
      heap = Heap.new([5])
      heap.concat([3, 9]).should be(heap)
      heap.concat(1..2)
      drain(heap).should eq([1, 2, 3, 5, 9])
    end
  end

  describe "#clear" do
    it "removes every element" do
      heap = Heap.new([1, 2, 3])
      heap.clear.should be(heap)
      heap.empty?.should be_true
      heap.pop?.should be_nil
    end
  end

  describe "#dup" do
    it "copies the elements but not the identity" do
      heap = Heap.new([2, 1])
      copy = heap.dup
      copy.push(0)
      heap.size.should eq(2)
      drain(copy).should eq([0, 1, 2])
      drain(heap).should eq([1, 2])
    end
  end

  describe "#each" do
    it "yields every element in unspecified order" do
      heap = Heap.new([3, 1, 2])
      seen = [] of Int32
      heap.each { |x| seen << x }
      seen.sort.should eq([1, 2, 3])
      heap.to_a.sort.should eq([1, 2, 3])
      heap.includes?(2).should be_true
      heap.includes?(4).should be_false
    end
  end

  describe "#inspect" do
    it "prints the elements" do
      Heap.new([1]).inspect.should eq("Heap{1}")
      Heap(Int32).new.to_s.should eq("Heap{}")
    end
  end

  it "raises ArgumentError when elements do not compare" do
    heap = Heap.new([1.0, 2.0])
    expect_raises(ArgumentError, "Comparison of") { heap.push(Float64::NAN) }
  end

  it "orders a union of comparable types" do
    heap = Heap(Int32 | Int64).new
    heap << 3_i64 << 1 << 2_i64
    drain(heap).should eq([1, 2_i64, 3_i64])
  end

  it "accepts a comparator that may return nil" do
    heap = Heap(Float64).new { |a, b| b <=> a }
    heap << 1.5 << 2.5
    heap.pop.should eq(2.5)
    expect_raises(ArgumentError, "Comparison of") { heap.push(Float64::NAN) }
  end

  it "keeps the comparator across dup" do
    heap = Heap(Int32).new { |a, b| b <=> a }
    heap << 1 << 2
    drain(heap.dup).should eq([2, 1])
  end

  it "rebuilds correctly when concat adds more than it holds" do
    rng = Random.new(3)
    heap = Heap.new([rng.rand(100), rng.rand(100)])
    extra = Array.new(500) { rng.rand(100) }
    expected = (heap.to_a + extra).sort
    heap.concat(extra)
    drain(heap).should eq(expected)
  end

  it "matches sorting on random input" do
    rng = Random.new(42)
    values = Array.new(1000) { rng.rand(-500..500) }
    drain(Heap.new(values)).should eq(values.sort)
    heap = Heap(Int32).new
    values.each { |v| heap.push(v) }
    drain(heap).should eq(values.sort)
  end

  it "matches sorting under interleaved push and pop" do
    rng = Random.new(7)
    heap = Heap(Int32).new
    model = [] of Int32
    2000.times do
      if model.empty? || rng.rand < 0.6
        v = rng.rand(1000)
        heap.push(v)
        model << v
      else
        heap.pop.should eq(model.min)
        model.delete_at(model.index!(model.min))
      end
      heap.size.should eq(model.size)
      heap.peek?.should eq(model.min?)
    end
  end
end

private def drain(heap)
  result = [] of typeof(heap.pop)
  while value = heap.pop?
    result << value
  end
  result
end
