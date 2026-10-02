require "spec"
require "radix_tree"

private def tree_of(*keys : String) : RadixTree(Int32)
  tree = RadixTree(Int32).new
  keys.each_with_index { |key, i| tree[key] = i }
  tree.check_invariants
  tree
end

# Byte-wise order, which `String#<=>` also follows.
private def sorted_keys(keys : Enumerable(String)) : Array(String)
  keys.to_a.sort_by!(&.to_slice)
end

describe RadixTree do
  describe ".new" do
    it "creates an empty tree" do
      tree = RadixTree(Int32).new
      tree.size.should eq(0)
      tree.empty?.should be_true
      tree.to_a.should be_empty
      tree["a"]?.should be_nil
      tree[""]?.should be_nil
      tree.longest_prefix("abc").should be_nil
      tree.with_prefix("").to_a.should be_empty
      tree.check_invariants
    end

    it "builds from a Hash" do
      tree = RadixTree.new({"b" => 2, "a" => 1})
      tree.should be_a(RadixTree(Int32))
      tree.to_a.should eq([{"a", 1}, {"b", 2}])
    end

    it "builds from an Enumerable of String or Bytes pairs" do
      RadixTree.new([{"x", 1}, {"y", 2}, {"x", 3}]).to_a.should eq([{"x", 3}, {"y", 2}])
      RadixTree.new([{"x".to_slice, 'a'}]).to_a.should eq([{"x", 'a'}])
    end

    it "supports the hash-like literal" do
      tree = RadixTree(Int32){"a" => 1, "b" => 2}
      tree.size.should eq(2)
    end
  end

  describe "#[]=" do
    it "stores and overwrites" do
      tree = RadixTree(String).new
      (tree["a"] = "x").should eq("x")
      tree["a"] = "y"
      tree.size.should eq(1)
      tree["a"].should eq("y")
    end

    it "splits an edge when a key ends inside it" do
      tree = tree_of("romane", "rom")
      tree.keys.should eq(["rom", "romane"])
      tree["rom"].should eq(1)
      tree["romane"].should eq(0)
      tree["roma"]?.should be_nil
      tree["ro"]?.should be_nil
    end

    it "splits an edge when keys diverge inside it" do
      tree = tree_of("romane", "romulus", "rubens", "ruber", "rubicon", "rubicundus")
      tree.keys.should eq(%w(romane romulus rubens ruber rubicon rubicundus))
      tree.size.should eq(6)
      tree["rub"]?.should be_nil
      tree["rube"]?.should be_nil
      tree["rubicundus"].should eq(5)
    end

    it "extends below an existing key" do
      tree = tree_of("a", "ab", "abc", "abcd")
      tree.to_a.should eq([{"a", 0}, {"ab", 1}, {"abc", 2}, {"abcd", 3}])
    end

    it "adds a value to an existing split node" do
      tree = tree_of("abc", "abd", "ab")
      tree["ab"].should eq(2)
      tree.size.should eq(3)
    end

    it "stores the empty key at the root" do
      tree = tree_of("", "a")
      tree[""].should eq(0)
      tree.keys.should eq(["", "a"])
      tree.longest_prefix("zzz").should eq({"", 0})
      tree.delete("").should eq(0)
      tree[""]?.should be_nil
      tree.keys.should eq(["a"])
      tree.check_invariants
    end

    it "copies Bytes keys" do
      bytes = "hello".to_slice.dup
      tree = RadixTree(Int32).new
      tree[bytes] = 1
      bytes[0] = 'j'.ord.to_u8
      tree["hello"].should eq(1)
      tree["jello"]?.should be_nil
      tree.keys.should eq(["hello"])
      tree.check_invariants
    end

    it "treats String and Bytes keys as the same key" do
      tree = RadixTree(Int32).new
      tree["abc"] = 1
      tree["abc".to_slice] = 2
      tree.size.should eq(1)
      tree["abc"].should eq(2)
      tree[Bytes[97, 98, 99]].should eq(2)
    end

    it "accepts keys that are not valid UTF-8" do
      tree = RadixTree(Int32).new
      bad = Bytes[0xff, 0xfe, 0x00, 0x80]
      tree[bad] = 1
      tree[Bytes[0xff]] = 2
      tree[Bytes[0x00]] = 3
      tree[bad].should eq(1)
      tree.keys.map(&.to_slice).should eq([Bytes[0x00], Bytes[0xff], bad])
      tree.keys.last.valid_encoding?.should be_false
      tree.longest_prefix(Bytes[0xff, 0xfe, 0x00, 0x80, 1]).should eq({String.new(bad), 1})
      tree.check_invariants
    end

    it "orders keys byte-wise, including high bytes" do
      keys = ["b", "a", "ab", "", "é", "z", "\u{10000}", "a\u0000", "A"]
      tree = tree_of(*{"b", "a", "ab", "", "é", "z", "\u{10000}", "a\u0000", "A"})
      tree.keys.should eq(sorted_keys(keys))
    end
  end

  describe "#put" do
    it "returns the previous value" do
      tree = RadixTree(Int32).new
      tree.put("a", 1).should be_nil
      tree.put("a", 2).should eq(1)
      tree.put("a".to_slice, 3).should eq(2)
      tree["a"].should eq(3)
    end
  end

  describe "#put_if_absent" do
    it "stores only when absent" do
      tree = RadixTree(Int32).new
      tree.put_if_absent("abc", &.bytesize).should eq(3)
      tree.put_if_absent("abc") { 0 }.should eq(3)
      tree.put_if_absent("abd", 7).should eq(7)
      tree.put_if_absent("abd", 8).should eq(7)
      tree.size.should eq(2)
      tree.check_invariants
    end
  end

  describe "#[] and #[]?" do
    it "raises KeyError for a missing key" do
      tree = tree_of("abc")
      expect_raises(KeyError, %(Missing radix tree key: "ab")) { tree["ab"] }
      expect_raises(KeyError) { tree["abcd".to_slice] }
      tree["abc".to_slice].should eq(0)
    end

    it "misses on keys that diverge, end early or run past" do
      tree = tree_of("abcdef", "abcxyz")
      tree["abc"]?.should be_nil
      tree["abcde"]?.should be_nil
      tree["abcdefg"]?.should be_nil
      tree["abd"]?.should be_nil
      tree["b"]?.should be_nil
      tree[""]?.should be_nil
    end
  end

  describe "#fetch" do
    it "returns the default or the block's result" do
      tree = tree_of("a")
      tree.fetch("a", 5).should eq(0)
      tree.fetch("b", 5).should eq(5)
      tree.fetch("b".to_slice, nil).should be_nil
      tree.fetch("bc", &.bytesize).should eq(2)
      tree.fetch("a") { 9 }.should eq(0)
    end
  end

  describe "#has_key?, #has_prefix?, #has_value?" do
    it "answers" do
      tree = tree_of("abc", "abd")
      tree.has_key?("abc").should be_true
      tree.has_key?("ab").should be_false
      tree.has_key?("abd".to_slice).should be_true
      tree.has_prefix?("ab").should be_true
      tree.has_prefix?("a".to_slice).should be_true
      tree.has_prefix?("abc").should be_true
      tree.has_prefix?("abcd").should be_false
      tree.has_prefix?("b").should be_false
      tree.has_prefix?("").should be_true
      RadixTree(Int32).new.has_prefix?("").should be_false
      tree.has_value?(1).should be_true
      tree.has_value?(2).should be_false
    end
  end

  describe "with a nilable value type" do
    it "distinguishes a stored nil from a missing key" do
      tree = RadixTree(Int32?).new
      tree["a"] = nil
      tree["ab"] = 1
      tree.has_key?("a").should be_true
      tree.size.should eq(2)
      tree["a"].should be_nil
      tree.fetch("a", 5).should be_nil
      tree.fetch("b", 5).should eq(5)
      tree.longest_prefix("az").should eq({"a", nil})
      tree.to_a.should eq([{"a", nil}, {"ab", 1}])
      tree.put("a", 2).should be_nil
      tree["a"] = nil
      tree.delete("a").should be_nil
      tree.has_key?("a").should be_false
      tree.check_invariants
    end
  end

  it "works with value types of any size" do
    nils = RadixTree(Nil).new
    nils["a"] = nil
    nils["ab"] = nil
    nils.keys.should eq(["a", "ab"])
    nils.delete("a")
    nils.check_invariants

    big = RadixTree({Int64, String, Float64, Int128}).new
    20.times { |i| big["k#{i}"] = {i.to_i64, i.to_s, i / 2, i.to_i128 << 100} }
    big["k7"].should eq({7_i64, "7", 3.5, 7.to_i128 << 100})
    big.delete("k1").should eq({1_i64, "1", 0.5, 1.to_i128 << 100})
    big.check_invariants
    big.size.should eq(19)
  end

  describe "#delete" do
    it "returns the value, or nil when missing" do
      tree = tree_of("a", "b")
      tree.delete("a").should eq(0)
      tree.delete("a").should be_nil
      tree.delete("zzz").should be_nil
      tree.delete("b".to_slice).should eq(1)
      tree.empty?.should be_true
      tree.check_invariants
    end

    it "yields when the key is missing" do
      tree = tree_of("a")
      tree.delete("b") { |key| "no #{key}" }.should eq("no b")
      tree.delete("a") { "never" }.should eq(0)
    end

    it "does not delete a key that is only a path through the tree" do
      tree = tree_of("abc", "abd")
      tree.delete("ab").should be_nil
      tree.delete("abcd").should be_nil
      tree.delete("a").should be_nil
      tree.size.should eq(2)
      tree.check_invariants
    end

    it "merges a node left with one child and no value into the child" do
      tree = tree_of("rom", "romane", "romulus")
      tree.delete("rom")
      tree.check_invariants
      tree.delete("romane")
      tree.check_invariants
      tree.keys.should eq(["romulus"])
      tree["romulus"].should eq(2)
      tree.longest_prefix("romulusx").should eq({"romulus", 2})
    end

    it "merges the parent after removing a leaf" do
      tree = tree_of("test", "toaster", "toasting", "slow", "slowly")
      tree.delete("toasting")
      tree.check_invariants
      tree.keys.should eq(%w(slow slowly test toaster))
      tree.delete("test")
      tree.check_invariants
      tree.delete("slow")
      tree.check_invariants
      tree.keys.should eq(%w(slowly toaster))
      tree.with_prefix("to").to_a.should eq([{"toaster", 1}])
    end

    it "keeps the root when it has a value and one child" do
      tree = tree_of("", "abc", "abd")
      tree.delete("abc")
      tree.check_invariants
      tree.to_a.should eq([{"", 0}, {"abd", 2}])
    end

    it "removes everything in any order" do
      keys = %w(a ab abc abd b ba bab x xyz xyzz)
      keys.each_permutation(keys.size, reuse: true).first(20).each do |order|
        tree = tree_of(*{"a", "ab", "abc", "abd", "b", "ba", "bab", "x", "xyz", "xyzz"})
        order.each do |key|
          tree.has_key?(key).should be_true
          tree.delete(key)
          tree.has_key?(key).should be_false
          tree.check_invariants
        end
        tree.empty?.should be_true
      end
    end

    it "frees edges that a re-insert then reuses" do
      tree = tree_of("abc", "abd")
      tree.delete("abc")
      tree.delete("abd")
      tree["abe"] = 5
      tree["ab"] = 6
      tree.check_invariants
      tree.to_a.should eq([{"ab", 6}, {"abe", 5}])
    end
  end

  describe "#clear" do
    it "empties the tree" do
      tree = tree_of("a", "b")
      tree.clear.should be(tree)
      tree.empty?.should be_true
      tree["a"]?.should be_nil
      tree["a"] = 1
      tree.size.should eq(1)
    end
  end

  describe "#longest_prefix" do
    tree = tree_of("/", "/api", "/api/v1", "/api/v1/users", "/static/")

    it "finds the longest stored prefix" do
      tree.longest_prefix("/api/v1/users/42").should eq({"/api/v1/users", 3})
      tree.longest_prefix("/api/v1/user").should eq({"/api/v1", 2})
      tree.longest_prefix("/api/v1").should eq({"/api/v1", 2})
      tree.longest_prefix("/api/").should eq({"/api", 1})
      tree.longest_prefix("/apx").should eq({"/", 0})
      tree.longest_prefix("/static").should eq({"/", 0})
      tree.longest_prefix("/static/x".to_slice).should eq({"/static/", 4})
      tree.longest_prefix("api").should be_nil
      tree.longest_prefix("").should be_nil
    end

    it "has value and key variants" do
      tree.longest_prefix_value("/api/v2").should eq(1)
      tree.longest_prefix_value("x").should be_nil
      tree.longest_prefix_value("/api/v1/users/7".to_slice).should eq(3)
      tree.longest_prefix_key("/api/v2").should eq("/api")
      tree.longest_prefix_key("x").should be_nil
    end

    it "returns the stored key without allocating a new one" do
      key = "/api/v9"
      t = RadixTree(Int32).new
      t[key] = 1
      t.longest_prefix("/api/v9/x").not_nil![0].should be(key)
    end
  end

  describe "#each_prefix" do
    it "yields every stored prefix, shortest first" do
      tree = tree_of("", "a", "ab", "abc", "abd", "b")
      tree.prefixes_of("abcd").should eq([{"", 0}, {"a", 1}, {"ab", 2}, {"abc", 3}])
      tree.prefixes_of("ab".to_slice).should eq([{"", 0}, {"a", 1}, {"ab", 2}])
      tree.prefixes_of("x").should eq([{"", 0}])
      seen = [] of String
      tree.each_prefix("abc") { |key, _| seen << key }
      seen.should eq(["", "a", "ab", "abc"])
    end

    it "stops on break" do
      tree = tree_of("a", "ab", "abc")
      seen = [] of String
      tree.each_prefix("abc") do |key, _|
        seen << key
        break if key == "ab"
      end
      seen.should eq(["a", "ab"])
    end
  end

  describe "#each_with_prefix and #with_prefix" do
    tree = tree_of("car", "cart", "carts", "cat", "dog", "ca", "c", "cb")

    it "yields keys under the prefix in byte order" do
      entries = [] of {String, Int32}
      tree.each_with_prefix("car") { |key, value| entries << {key, value} }
      entries.should eq([{"car", 0}, {"cart", 1}, {"carts", 2}])
      tree.with_prefix("ca").map(&.[0]).to_a.should eq(%w(ca car cart carts cat))
      tree.with_prefix("ca".to_slice).map(&.[0]).to_a.should eq(%w(ca car cart carts cat))
      tree.keys_with_prefix("c").should eq(%w(c ca car cart carts cat cb))
    end

    it "matches a prefix that ends inside an edge" do
      tree.keys_with_prefix("cart").should eq(%w(cart carts))
      tree.keys_with_prefix("carts").should eq(%w(carts))
      tree.keys_with_prefix("do").should eq(%w(dog))
      tree.keys_with_prefix("cartsy").should be_empty
      tree.keys_with_prefix("dot").should be_empty
      tree.keys_with_prefix("e").should be_empty
    end

    it "yields everything for the empty prefix" do
      tree.keys_with_prefix("").should eq(tree.keys)
      tree.with_prefix("").to_a.should eq(tree.to_a)
    end

    it "stops on break and on return" do
      seen = [] of String
      tree.each_with_prefix("ca") do |key, _|
        seen << key
        break if seen.size == 2
      end
      seen.should eq(["ca", "car"])
      first_with(tree, "car").should eq("car")
      tree.each_key_with_prefix("c") { |key| break key }.should eq("c")
    end

    it "the iterator can be consumed partially and keeps going" do
      iter = tree.with_prefix("c")
      iter.next.should eq({"c", 6})
      iter.next.should eq({"ca", 5})
      iter.first(2).to_a.should eq([{"car", 0}, {"cart", 1}])
    end
  end

  describe "iteration" do
    tree = tree_of("b", "a", "abc", "ab", "")

    it "#each yields entries in byte order" do
      entries = [] of {String, Int32}
      tree.each { |key, value| entries << {key, value} }
      entries.should eq([{"", 4}, {"a", 1}, {"ab", 3}, {"abc", 2}, {"b", 0}])
      tree.each.to_a.should eq(entries)
      tree.to_a.should eq(entries)
    end

    it "keys, values and their iterators" do
      tree.keys.should eq(["", "a", "ab", "abc", "b"])
      tree.values.should eq([4, 1, 3, 2, 0])
      tree.each_key.to_a.should eq(tree.keys)
      tree.each_value.to_a.should eq(tree.values)
      keys = [] of String
      tree.each_key { |key| keys << key }
      keys.should eq(tree.keys)
      values = [] of Int32
      tree.each_value { |value| values << value }
      values.should eq(tree.values)
    end

    it "stops every yielding iteration on break" do
      tree.each { |key, _| break key if key == "ab" }.should eq("ab")
      tree.each_key { |key| break key if key.size == 3 }.should eq("abc")
      tree.each_value { |value| break value if value < 2 }.should eq(1)
      count = 0
      tree.each do
        count += 1
        break
      end
      count.should eq(1)
    end

    it "includes Enumerable and Iterable" do
      tree.map(&.[1]).sum.should eq(10)
      tree.find { |key, _| key.starts_with?("ab") }.should eq({"ab", 3})
      tree.first.should eq({"", 4})
      tree.each_slice(2).to_a.size.should eq(3)
      tree.to_h.should eq({"" => 4, "a" => 1, "ab" => 3, "abc" => 2, "b" => 0})
    end

    it "survives mutation during iteration" do
      t = tree_of("a", "b", "c", "d")
      visited = [] of String
      t.each do |key, _|
        visited << key
        t.delete("c")
        t["e"] = 9
      end
      visited.should contain("a")
      t.check_invariants
    end
  end

  describe "#== and #hash" do
    it "compares keys and values" do
      a = tree_of("x", "y")
      b = RadixTree(Int32).new
      b["y"] = 1
      b["x"] = 0
      a.should eq(b)
      a.hash.should eq(b.hash)
      b["y"] = 2
      a.should_not eq(b)
      b["y"] = 1
      b["z"] = 3
      a.should_not eq(b)
      b.delete("z")
      b.delete("y")
      b["w"] = 1
      a.should_not eq(b)
      RadixTree(Int32).new.should eq(RadixTree(Int32).new)
    end
  end

  describe "#dup and #clone" do
    it "dup copies the structure but not the values" do
      a = RadixTree(Array(Int32)).new
      a["k"] = [1]
      a["kk"] = [2]
      b = a.dup
      b.check_invariants
      b.should eq(a)
      b["k2"] = [3]
      b.delete("kk")
      b.check_invariants
      a.keys.should eq(["k", "kk"])
      b.keys.should eq(["k", "k2"])
      b["k"].should be(a["k"])
    end

    it "clone copies the values" do
      a = RadixTree(Array(Int32)).new
      a["k"] = [1]
      b = a.clone
      b.should eq(a)
      b["k"].should_not be(a["k"])
    end
  end

  describe "#to_s and #inspect" do
    it "prints like a Hash" do
      tree = tree_of("b", "a")
      tree.to_s.should eq(%(RadixTree{"a" => 1, "b" => 0}))
      tree.inspect.should eq(%(RadixTree{"a" => 1, "b" => 0}))
      RadixTree(Int32).new.to_s.should eq("RadixTree{}")
      tree.pretty_inspect.should eq(%(RadixTree{"a" => 1, "b" => 0}))
    end
  end

  it "finds children at every position of a node, as it grows and shrinks" do
    # Nodes keep up to 16 first bytes inline, searched a word at a time;
    # cover both words and the move out of line.
    tree = RadixTree(Int32).new
    letters = ('a'..'z').to_a.shuffle(Random.new(3))
    letters.each_with_index do |c, n|
      tree["x#{c}"] = n
      tree.check_invariants
      letters.each_with_index do |d, m|
        tree["x#{d}"]?.should eq(m <= n ? m : nil)
        tree["x#{d}!"]?.should be_nil
      end
      tree["x\u0000"]?.should be_nil
      tree["x~"]?.should be_nil
    end
    letters.each_with_index do |c, n|
      tree.delete("x#{c}").should eq(n)
      tree.check_invariants
      letters.each_with_index { |d, m| tree["x#{d}"]?.should eq(m > n ? m : nil) }
    end
  end

  it "iterates deep trees (beyond the initial traversal stack)" do
    tree = RadixTree(Int32).new
    keys = (1..100).flat_map { |n| ["a" * n, "a" * n + "b"] }
    keys.each_with_index { |key, i| tree[key] = i }
    tree.check_invariants
    tree.keys.should eq(sorted_keys(keys))
    tree.each_key.to_a.should eq(sorted_keys(keys))
    tree.keys_with_prefix("a" * 50).size.should eq(102)
    tree.with_prefix("a" * 50).to_a.size.should eq(102)
    tree.prefixes_of("a" * 30 + "b").size.should eq(31)
  end

  it "handles wide nodes (every byte value under one parent)" do
    tree = RadixTree(Int32).new
    256.times.to_a.reverse.each do |b|
      tree[Bytes[b.to_u8]] = b
      tree[Bytes[b.to_u8, 1]] = b + 1000
    end
    tree.size.should eq(512)
    tree.check_invariants
    tree.keys.map(&.to_slice).should eq(tree.keys.map(&.to_slice).sort)
    256.times { |b| tree[Bytes[b.to_u8]].should eq(b) }
    256.times { |b| tree.delete(Bytes[b.to_u8]).should eq(b) if b.even? }
    tree.check_invariants
    tree.size.should eq(384)
  end

  it "matches a Hash under random operations" do
    rng = Random.new(42)
    # "a", "b", "/", "é" (two bytes), NUL and an invalid UTF-8 byte.
    alphabet = Bytes[97, 98, 47, 0xc3, 0xa9, 0, 0xff]
    random_key = ->(max : Int32) do
      String.new(Bytes.new(rng.rand(max + 1)) { alphabet[rng.rand(alphabet.size)] })
    end

    {3, 6, 12}.each do |max_len|
      tree = RadixTree(Int32).new
      model = {} of String => Int32
      4000.times do |step|
        key = random_key.call(max_len)
        bytes_key = rng.rand(2) == 0
        case rng.rand(12)
        when 0..3
          if bytes_key
            tree[key.to_slice] = step
          else
            tree[key] = step
          end
          model[key] = step
        when 4..6
          (bytes_key ? tree.delete(key.to_slice) : tree.delete(key)).should eq(model.delete(key))
        when 7, 8
          tree[key]?.should eq(model[key]?)
          tree.has_key?(key.to_slice).should eq(model.has_key?(key))
        when 9
          best = model.keys.select { |k| key.to_slice[0, Math.min(k.bytesize, key.bytesize)] == k.to_slice && k.bytesize <= key.bytesize }
            .max_by?(&.bytesize)
          tree.longest_prefix(key).should eq(best.try { |k| {k, model[k]} })
          tree.longest_prefix_value(key.to_slice).should eq(best.try { |k| model[k] })
          expected = model.keys.select { |k| k.bytesize <= key.bytesize && key.to_slice[0, k.bytesize] == k.to_slice }.sort_by!(&.bytesize)
          tree.prefixes_of(key).map(&.[0]).should eq(expected)
        when 10
          prefix = random_key.call(max_len // 2)
          expected = sorted_keys(model.keys.select { |k| k.bytesize >= prefix.bytesize && k.to_slice[0, prefix.bytesize] == prefix.to_slice })
          tree.keys_with_prefix(prefix).should eq(expected)
          tree.with_prefix(prefix.to_slice).map { |k, v| {k, v} }.to_a.should eq(expected.map { |k| {k, model[k]} })
          tree.has_prefix?(prefix).should eq(!expected.empty?)
        else
          tree.size.should eq(model.size)
        end
        tree.check_invariants if step % 97 == 0
      end
      tree.check_invariants
      tree.size.should eq(model.size)
      tree.to_a.should eq(sorted_keys(model.keys).map { |k| {k, model[k]} })
      model.keys.each { |k| tree.delete(k).should eq(model[k]) }
      tree.empty?.should be_true
      tree.check_invariants
    end
  end
end

private def first_with(tree, prefix)
  tree.each_with_prefix(prefix) { |key, _| return key }
  nil
end
