require "spec"
require "http/headers"
require "json"
require "yaml"
require "../../support/wasm32"

describe HTTP::Headers do
  it "is empty" do
    headers = HTTP::Headers.new
    headers.empty?.should be_true
  end

  it "is case insensitive" do
    headers = HTTP::Headers{"Foo" => "bar"}
    headers["foo"].should eq("bar")
  end

  it "it allows indifferent access for underscore and dash separated keys" do
    headers = HTTP::Headers{"foo_Bar" => "bar", "Foobar-foo" => "baz"}
    headers["foo-bar"].should eq("bar")
    headers["foobar_foo"].should eq("baz")
  end

  it "raises an error if header value contains invalid character" do
    expect_raises ArgumentError do
      HTTP::Headers{"invalid-header" => "\r\nLocation: http://example.com"}
    end
  end

  it "should retain the input casing" do
    headers = HTTP::Headers{"FOO_BAR" => "bar", "Foobar-foo" => "baz"}
    serialized = String.build do |io|
      headers.each do |name, values|
        io << name << ": " << values.first << ';'
      end
    end

    serialized.should eq("FOO_BAR: bar;Foobar-foo: baz;")
  end

  it "is gets with []?" do
    headers = HTTP::Headers.new
    headers["foo"]?.should be_nil

    headers["Foo"] = "bar"
    headers["foo"]?.should eq("bar")
  end

  it "fetches with default value" do
    headers = HTTP::Headers.new
    headers.fetch("foo", "baz").should eq("baz")

    headers["Foo"] = "bar"
    headers.fetch("foo", "baz").should eq("bar")
  end

  it "fetches with block" do
    headers = HTTP::Headers.new
    headers.fetch("foo") { |k| "#{k}baz" }.should eq("foobaz")

    headers["Foo"] = "bar"
    headers.fetch("foo") { "baz" }.should eq("bar")
  end

  it "has key" do
    headers = HTTP::Headers{"Foo" => "bar"}
    headers.has_key?("foo").should be_true
    headers.has_key?("bar").should be_false
  end

  it "deletes" do
    headers = HTTP::Headers{"Foo" => "bar"}
    headers.delete("foo").should eq("bar")
    headers.should be_empty
  end

  describe "#==" do
    it "equals other instance" do
      a = HTTP::Headers{"Foo" => "bar"}
      b = HTTP::Headers{"Foo" => "bar"}
      c = HTTP::Headers{"Foo" => "baz"}
      a.should eq b
      a.hash.should eq b.hash
      a.should_not eq c
      a.hash.should_not eq c.hash
    end

    it "case-insensitive keys" do
      a = HTTP::Headers{"Foo" => "bar"}
      b = HTTP::Headers{"foo" => "bar"}
      c = HTTP::Headers{"voo" => "bar"}
      a.should eq b
      a.hash.should eq b.hash
      a.should_not eq c
      a.hash.should_not eq c.hash
    end

    it "different internal representation" do
      a = HTTP::Headers{"Foo" => "bar"}
      b = HTTP::Headers{"Foo" => ["bar"]}
      c = HTTP::Headers{"Foo" => ["bar", "baz"]}
      a.should eq b
      a.hash.should eq b.hash
      a.should_not eq c
      a.hash.should_not eq c.hash
    end
  end

  describe "Key#hash" do
    # Keys are normalized eight bytes at a time; cover every position within a
    # word, the word/tail boundaries and the internal chunk size.
    it "matches for names that differ only in case or '_' vs '-'" do
      [1, 4, 7, 8, 9, 12, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 200].each do |len|
        base = String.build { |io| len.times { |i| io << ((i % 5 == 4) ? '-' : ('a' + i % 26)) } }
        variant = String.build do |io|
          base.each_char_with_index do |c, i|
            io << (c == '-' ? (i.odd? ? '_' : '-') : (i.odd? ? c.upcase : c))
          end
        end
        a = HTTP::Headers::Key.new(base)
        b = HTTP::Headers::Key.new(variant)
        a.should eq(b), "len=#{len}"
        a.hash.should eq(b.hash), "len=#{len}"
      end
    end

    it "distinguishes names that differ in one byte at any position" do
      base = "x" * 70
      70.times do |i|
        other = base.sub(i, 'y')
        HTTP::Headers::Key.new(base).should_not eq HTTP::Headers::Key.new(other)
        HTTP::Headers::Key.new(base).hash.should_not eq HTTP::Headers::Key.new(other).hash
      end
    end

    it "only folds ASCII letters and '_'" do
      # Neighbours of the folded ranges must stay distinct: '@' (0x40) / '[' (0x5B) / '`' / '{' / DEL / high bytes.
      pairs = {
        {"@", "`"}, {"[", "{"}, {"\u{5e}", "\u{7e}"}, {"\u{7f}", "\u{5f}"}, {"\u{c0}", "\u{e0}"}, {"\u{c1}", "\u{e1}"},
        {"\u{5f}", "\u{2d}"}, # '_' and '-' *are* the same
      }
      pairs.each do |x, y|
        a = HTTP::Headers::Key.new("k#{x}k")
        b = HTTP::Headers::Key.new("k#{y}k")
        if x == "\u{5f}"
          a.should eq b
          a.hash.should eq b.hash
        else
          a.should_not eq b
          a.hash.should_not eq b.hash
        end
      end
    end

    it "looks up long header names case-insensitively" do
      name = "X-" + "Very-Long-Header-Name-" * 6
      name.bytesize.should be > 64
      headers = HTTP::Headers{name => "v"}
      headers[name.downcase].should eq "v"
      headers[name.upcase.tr("-", "_")].should eq "v"
      headers[name.downcase.sub(-1, 'x')]?.should be_nil
    end
  end

  it "dups" do
    headers = HTTP::Headers{"Foo" => "bar"}
    other = headers.dup
    other.should be_a(HTTP::Headers)
    other["foo"].should eq("bar")

    other["Baz"] = "Qux"
    headers["baz"]?.should be_nil
  end

  it "clones" do
    headers = HTTP::Headers{"Foo" => "bar"}
    other = headers.clone
    other.should be_a(HTTP::Headers)
    other["foo"].should eq("bar")

    other["Baz"] = "Qux"
    headers["baz"]?.should be_nil
  end

  describe "#[]=(String)" do
    it "raises on invalid name" do
      headers = HTTP::Headers.new
      expect_raises(ArgumentError, "Invalid header name") do
        headers[""] = "bar"
      end
      expect_raises(ArgumentError, "Invalid header name") do
        headers["ä"] = "bar"
      end
      expect_raises(ArgumentError, "Invalid header name") do
        headers["Foo: foo\r\nBar"] = "bar"
      end
    end
  end

  describe "#[]=(Array)" do
    it "raises on invalid name" do
      headers = HTTP::Headers.new
      expect_raises(ArgumentError, "Invalid header name") do
        headers[""] = ["bar"]
      end
      expect_raises(ArgumentError, "Invalid header name") do
        headers["ä"] = ["bar"]
      end
      expect_raises(ArgumentError, "Invalid header name") do
        headers["Foo: foo\r\nBar"] = ["bar"]
      end
    end
  end

  describe "#add(String)" do
    it "adds string" do
      headers = HTTP::Headers.new
      headers.add("foo", "bar")
      headers.add("foo", "baz")
      headers["foo"].should eq("bar,baz")
    end

    it "raises on invalid name" do
      headers = HTTP::Headers.new
      expect_raises(ArgumentError, "Invalid header name") do
        headers.add("", "bar")
      end
      expect_raises(ArgumentError, "Invalid header name") do
        headers.add("ä", "bar")
      end
      expect_raises(ArgumentError, "Invalid header name") do
        headers.add("Foo: foo\r\nBar", "bar")
      end
    end
  end

  describe "#add(Array)" do
    it "adds array of string" do
      headers = HTTP::Headers.new
      headers.add("foo", "bar")
      headers.add("foo", ["baz", "qux"])
      headers["foo"].should eq("bar,baz,qux")
    end

    it "raises on invalid name" do
      headers = HTTP::Headers.new
      expect_raises(ArgumentError, "Invalid header name") do
        headers.add("", ["bar"])
      end
      expect_raises(ArgumentError, "Invalid header name") do
        headers.add("ä", ["bar"])
      end
      expect_raises(ArgumentError, "Invalid header name") do
        headers.add("Foo: foo\r\nBar", ["bar"])
      end
    end
  end

  describe "#add?(String)" do
    it "returns false on invalid name" do
      headers = HTTP::Headers.new
      headers.add?("", "bar").should be_false
      headers.add?("ä", "bar").should be_false
      headers.add?("Foo: foo\r\nBar", "bar").should be_false
    end
  end

  describe "#add?(Array)" do
    it "returns false on invalid name" do
      headers = HTTP::Headers.new
      headers.add?("", ["bar"]).should be_false
      headers.add?("ä", ["bar"]).should be_false
      headers.add?("Foo: foo\r\nBar", ["bar"]).should be_false
    end
  end

  it "gets all values" do
    headers = HTTP::Headers{"foo" => "bar"}
    headers.get("foo").should eq(["bar"])

    headers.get?("foo").should eq(["bar"])
    headers.get?("qux").should be_nil
  end

  it "does to_s" do
    headers = HTTP::Headers{"Foo_quux" => "bar", "Baz-Quux" => ["a", "b"]}
    headers.to_s.should eq(%(HTTP::Headers{"Foo_quux" => "bar", "Baz-Quux" => ["a", "b"]}))
  end

  it "#serialize" do
    headers = HTTP::Headers{"Foo_quux" => "bar", "Baz-Quux" => ["a", "b"]}
    headers.serialize.should eq("Foo_quux: bar\r\nBaz-Quux: a\r\nBaz-Quux: b\r\n")
  end

  describe "serializes" do
    it "#to_json" do
      HTTP::Headers{"Foo_quux" => "bar", "Baz-Quux" => ["a", "b"]}.to_json.should eq <<-JSON
      {"Foo_quux":"bar","Baz-Quux":["a","b"]}
      JSON
    end

    pending_wasm32 "#to_yaml" do
      HTTP::Headers{"Foo_quux" => "bar", "Baz-Quux" => ["a", "b"]}.to_yaml.should eq <<-YAML
      ---
      Foo_quux: bar
      Baz-Quux:
      - a
      - b\n
      YAML
    end
  end

  describe "#merge" do
    it "merges into a new Headers instance" do
      headers = HTTP::Headers{"one" => "1", "two" => "2"}
      new_headers = headers.merge({"three" => "3"})

      new_headers.should eq HTTP::Headers{
        "one"   => "1",
        "two"   => "2",
        "three" => "3",
      }
      headers["three"]?.should be_nil
      new_headers.should_not be headers
    end

    it "merges other hash" do
      headers = HTTP::Headers{"foo" => "bar", "boo" => "baz"}
      new_headers = headers.merge({"foo" => "baz", "qux" => "quux"})
      new_headers.should eq HTTP::Headers{
        "foo" => "baz",
        "boo" => "baz",
        "qux" => "quux",
      }
    end

    it "raises an error if header value contains invalid character" do
      headers = HTTP::Headers.new
      expect_raises ArgumentError do
        headers.merge({"invalid-header" => "\r\nLocation: http://example.com"})
      end
    end
  end

  describe "#merge!" do
    it "merges and return self" do
      headers = HTTP::Headers.new
      headers.should be headers.merge!({"foo" => "bar"})
    end

    it "merges other headers" do
      headers = HTTP::Headers{"foo" => "bar", "boo" => "baz"}
      headers.merge!(HTTP::Headers{"foo" => "baz", "qux" => "quux"})
      headers.should eq HTTP::Headers{"foo" => "baz", "boo" => "baz", "qux" => "quux"}
    end

    it "merges other hash" do
      headers = HTTP::Headers{"foo" => "bar", "boo" => "baz"}
      headers.merge!({"foo" => "baz", "qux" => "quux"})
      headers.should eq HTTP::Headers{"foo" => "baz", "boo" => "baz", "qux" => "quux"}
    end

    it "raises an error if header value contains invalid character" do
      headers = HTTP::Headers.new
      expect_raises ArgumentError do
        headers.merge!({"invalid-header" => "\r\nLocation: http://example.com"})
      end
    end
  end

  it "dispatch with union type (#16622)" do
    headers = HTTP::Headers.new
    headers.merge!(HTTP::Headers.new)
    headers["foo"] = "bar".as(String | Array(String))
  end

  it "matches word" do
    headers = HTTP::Headers{"foo" => "bar"}
    headers.includes_word?("foo", "bar").should be_true
    headers.includes_word?("foo", "ba").should be_false
    headers.includes_word?("foo", "ar").should be_false
  end

  it "matches word with comma separated value" do
    headers = HTTP::Headers{"foo" => "bar, baz"}
    headers.includes_word?("foo", "bar").should be_true
    headers.includes_word?("foo", "baz").should be_true
    headers.includes_word?("foo", "ba").should be_false
  end

  it "matches word with comma separated value, case insensitive (#3626)" do
    headers = HTTP::Headers{"foo" => "BaR, BAZ"}
    headers.includes_word?("foo", "bar").should be_true
    headers.includes_word?("foo", "baz").should be_true
    headers.includes_word?("foo", "BAR").should be_true
    headers.includes_word?("foo", "ba").should be_false
  end

  it "doesn't match empty string" do
    headers = HTTP::Headers{"foo" => "bar, baz"}
    headers.includes_word?("foo", "").should be_false
  end

  it "matches word with comma separated value, partial match" do
    headers = HTTP::Headers{"foo" => "bar, bazo, baz"}
    headers.includes_word?("foo", "baz").should be_true
  end

  it "doesn't match word with comma separated value, partial match" do
    headers = HTTP::Headers{"foo" => "bar, bazo"}
    headers.includes_word?("foo", "baz").should be_false
  end

  it "matches word with comma separated value, partial match (array)" do
    headers = HTTP::Headers{"foo" => ["foo", "baz, bazo"]}
    headers.includes_word?("foo", "baz").should be_true
  end

  it "doesn't match word with comma separated value, partial match (array)" do
    headers = HTTP::Headers{"foo" => ["foo", "bar, bazo"]}
    headers.includes_word?("foo", "baz").should be_false
  end

  it "matches word among headers" do
    headers = HTTP::Headers.new
    headers.add("foo", "bar")
    headers.add("foo", "baz")
    headers.includes_word?("foo", "bar").should be_true
    headers.includes_word?("foo", "baz").should be_true
  end

  it "does not matches word if missing header" do
    headers = HTTP::Headers.new
    headers.includes_word?("foo", "bar").should be_false
    headers.includes_word?("foo", "").should be_false
  end

  it "can create header value with all US-ASCII visible chars (#2999)" do
    headers = HTTP::Headers.new
    value = (32..126).map(&.chr).join
    headers.add("foo", value)
  end

  it "validates content" do
    headers = HTTP::Headers.new
    valid_value = "foo"
    invalid_value = "\r\nLocation: http://example.com"
    headers.valid_value?(valid_value).should be_true
    headers.valid_value?(invalid_value).should be_false
    headers.add?("foo", valid_value).should be_true
    headers.add?("foo", [valid_value]).should be_true
    headers.add?("foobar", invalid_value).should be_false
    headers.add?("foobar", [invalid_value]).should be_false
  end
end
