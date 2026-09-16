require "spec"
require "base64"
require "crystal/digest/md5"
require "spec/helpers/string"

# rearrange parameters for `assert_prints`
{% for method in %w(encode strict_encode urlsafe_encode) %}
  private def base64_{{ method.id }}(io : IO, data, *args)
    Base64.{{ method.id }}(data, io, *args)
  end

  private def base64_{{ method.id }}(data, *args)
    Base64.{{ method.id }}(data, *args)
  end
{% end %}

describe "Base64" do
  context "simple test" do
    eqs = {"" => "", "a" => "YQ==\n", "ab" => "YWI=\n", "abc" => "YWJj\n",
           "abcd" => "YWJjZA==\n", "abcde" => "YWJjZGU=\n", "abcdef" => "YWJjZGVm\n",
           "abcdefg" => "YWJjZGVmZw==\n"}
    eqs.each do |a, b|
      it "encode #{a.inspect} to #{b.inspect}" do
        assert_prints base64_encode(a), b
      end
      it "decode from #{b.inspect} to #{a.inspect}" do
        Base64.decode(b).should eq(a.to_slice)
        Base64.decode_string(b).should eq(a)
      end
    end
  end

  context "\n in multiple places" do
    eqs = {"abcd" => "YWJj\nZA==\n", "abcde" => "YWJj\nZGU=\n", "abcdef" => "YWJj\nZGVm\n",
           "abcdefg" => "YWJj\nZGVmZw==\n",
    }
    eqs.each do |a, b|
      it "decode from #{b.inspect} to #{a.inspect}" do
        Base64.decode(b).should eq(a.to_slice)
        Base64.decode_string(b).should eq(a)
      end
    end
  end

  it "encodes byte slice" do
    slice = Bytes.new(5) { 1_u8 }
    assert_prints base64_encode(slice), "AQEBAQE=\n"
    assert_prints base64_strict_encode(slice), "AQEBAQE="
  end

  it "encodes empty slice" do
    slice = Bytes.empty
    assert_prints base64_encode(slice), ""
    assert_prints base64_strict_encode(slice), ""
  end

  it "encodes static array" do
    array = uninitialized StaticArray(UInt8, 5)
    (0...5).each { |i| array[i] = 1_u8 }
    assert_prints base64_encode(array), "AQEBAQE=\n"
    assert_prints base64_strict_encode(array), "AQEBAQE="
  end

  describe "base" do
    eqs = {"Send reinforcements"                                                    => "U2VuZCByZWluZm9yY2VtZW50cw==\n",
           "Now is the time for all good coders\nto learn Crystal"                  => "Tm93IGlzIHRoZSB0aW1lIGZvciBhbGwgZ29vZCBjb2RlcnMKdG8gbGVhcm4g\nQ3J5c3RhbA==\n",
           "This is line one\nThis is line two\nThis is line three\nAnd so on...\n" => "VGhpcyBpcyBsaW5lIG9uZQpUaGlzIGlzIGxpbmUgdHdvClRoaXMgaXMgbGlu\nZSB0aHJlZQpBbmQgc28gb24uLi4K\n",
           "hahah⊙ⓧ⊙"                                                               => "aGFoYWjiipnik6fiipk=\n"}
    eqs.each do |a, b|
      it "encode #{a.inspect} to #{b.inspect}" do
        assert_prints base64_encode(a), b
      end
      it "decode from #{b.inspect} to #{a.inspect}" do
        Base64.decode(b).should eq(a.to_slice)
        Base64.decode_string(b).should eq(a)
      end
    end

    it "decode from strict form" do
      Base64.decode_string("Tm93IGlzIHRoZSB0aW1lIGZvciBhbGwgZ29vZCBjb2RlcnMKdG8gbGVhcm4gQ3J5c3RhbA==").should eq(
        "Now is the time for all good coders\nto learn Crystal")
    end

    it "encode to stream returns number of written characters" do
      io = IO::Memory.new
      count = Base64.encode("Now is the time for all good coders\nto learn Crystal", io)
      count.should eq 74
    end

    it "decode from stream returns number of written bytes" do
      io = IO::Memory.new
      count = Base64.decode("Tm93IGlzIHRoZSB0aW1lIGZvciBhbGwgZ29vZCBjb2RlcnMKdG8gbGVhcm4gQ3J5c3RhbA==", io)
      count.should eq 52
    end

    it "big message" do
      a = "a" * 100000
      b = Base64.encode(a)
      Crystal::Digest::MD5.hexdigest(Base64.decode_string(b)).should eq(Crystal::Digest::MD5.hexdigest(a))
    end

    it "works for most characters" do
      a = String.build(65536 * 4) do |buf|
        65536.times { |i| buf << (i + 1).unsafe_chr }
      end
      b = Base64.encode(a)
      Crystal::Digest::MD5.hexdigest(Base64.decode_string(b)).should eq(Crystal::Digest::MD5.hexdigest(a))
    end
  end

  describe "decode cases" do
    it "decode \r\n" do
      decoded = "hahah⊙ⓧ⊙"
      {"aGFo\r\nYWjiipnik6fiipk=\r\n", "aGFo\r\nYWjiipnik6fiipk=\r\n\r\n"}.each do |encoded|
        Base64.decode(encoded).should eq(decoded.to_slice)
        Base64.decode_string(encoded).should eq(decoded)
      end
    end

    it "decode \n in multiple places" do
      decoded = "hahah⊙ⓧ⊙"
      {"aGFoYWjiipnik6fiipk=", "aGFo\nYWjiipnik6fiipk=", "aGFo\nYWji\nipnik6fiipk=",
       "aGFo\nYWji\nipni\nk6fiipk=", "aGFo\nYWji\nipni\nk6fi\nipk=",
       "aGFo\nYWji\nipni\nk6fi\nipk=\n"}.each do |encoded|
        Base64.decode(encoded).should eq(decoded.to_slice)
        Base64.decode_string(encoded).should eq(decoded)
      end
    end

    it "raise error when \n in incorrect place" do
      expect_raises Base64::Error do
        Base64.decode("aG\nFoYWjiipnik6fiipk=")
      end

      expect_raises Base64::Error do
        Base64.decode_string("aG\nFoYWjiipnik6fiipk=")
      end
    end

    it "raise error when incorrect symbol" do
      expect_raises Base64::Error do
        Base64.decode("()")
      end

      expect_raises Base64::Error do
        Base64.decode_string("()")
      end
    end

    it "raise error when incorrect size" do
      expect_raises Base64::Error do
        Base64.decode("a")
      end

      expect_raises Base64::Error do
        Base64.decode_string("a")
      end
    end

    it "decode small tail after last \n, was a bug" do
      s = "Tm93IGlzIHRoZSB0aW1lIGZvciBhbGwgZ29vZCBjb2RlcnMKdG8gbGVhcm4g\nnA==\n"
      Base64.decode(s).should eq Bytes[78, 111, 119, 32, 105, 115, 32, 116, 104, 101, 32, 116, 105, 109, 101, 32, 102, 111, 114, 32, 97, 108, 108, 32, 103, 111, 111, 100, 32, 99, 111, 100, 101, 114, 115, 10, 116, 111, 32, 108, 101, 97, 114, 110, 32, 156]
    end
  end

  describe "strict" do
    it "encode" do
      assert_prints base64_strict_encode("Now is the time for all good coders\nto learn Crystal"),
        "Tm93IGlzIHRoZSB0aW1lIGZvciBhbGwgZ29vZCBjb2RlcnMKdG8gbGVhcm4gQ3J5c3RhbA=="
    end
    it "with spec symbols" do
      s = String.build { |b| (160..179).each { |i| b << i.chr } }
      se = "wqDCocKiwqPCpMKlwqbCp8KowqnCqsKrwqzCrcKuwq/CsMKxwrLCsw=="
      assert_prints base64_strict_encode(s), se
    end

    it "encode to stream returns number of written characters" do
      s = String.build { |b| (160..179).each { |i| b << i.chr } }
      io = IO::Memory.new
      Base64.strict_encode(s, io).should eq(56)
    end
  end

  describe "urlsafe" do
    it "work" do
      s = String.build { |b| (160..179).each { |i| b << i.chr } }
      se = "wqDCocKiwqPCpMKlwqbCp8KowqnCqsKrwqzCrcKuwq_CsMKxwrLCsw=="
      assert_prints base64_urlsafe_encode(s), se
    end

    it "encode to stream returns number of written characters" do
      s = String.build { |b| (160..179).each { |i| b << i.chr } }
      io = IO::Memory.new
      Base64.urlsafe_encode(s, io).should eq(56)
    end
  end

  describe "line boundaries" do
    it "matches a reference implementation around every line and group boundary" do
      (0..200).each do |size|
        data = Bytes.new(size) { |i| (i * 7 + 3).to_u8! }
        strict = Base64.strict_encode(data)
        strict.size.should eq((size + 2) // 3 * 4)
        lines = strict.each_char.each_slice(60).map(&.join).to_a
        Base64.encode(data).should eq(lines.map { |line| line + "\n" }.join)
        Base64.urlsafe_encode(data).should eq(strict.tr("+/", "-_"))
        Base64.urlsafe_encode(data, false).should eq(strict.tr("+/", "-_").rstrip('='))
        Base64.decode(strict).should eq(data)
        Base64.decode(Base64.encode(data)).should eq(data)
        Base64.decode_string(Base64.urlsafe_encode(data, false)).should eq(String.new(data))
      end
    end
  end

  describe "io chunking" do
    # Sizes around the internal chunk sizes (2880 input bytes per encoded
    # write, 3072 decoded bytes per write), plus tails of every length.
    sizes = [0, 1, 2, 3, 2879, 2880, 2881, 2882, 3070, 3071, 3072, 3073, 3074, 5759, 5760, 5761, 6143, 6144, 6145, 6146, 9000]

    it "encodes to a stream exactly like to a string" do
      sizes.each do |size|
        data = Bytes.new(size) { |i| (i * 31 + 5).to_u8! }
        {% for method in %w(encode strict_encode urlsafe_encode) %}
          io = IO::Memory.new
          Base64.{{ method.id }}(data, io).should eq(Base64.{{ method.id }}(data).bytesize)
          io.to_s.should eq(Base64.{{ method.id }}(data))
        {% end %}
      end
    end

    it "decodes to a stream exactly like to a slice" do
      sizes.each do |size|
        data = Bytes.new(size) { |i| (i * 31 + 5).to_u8! }
        [Base64.encode(data), Base64.strict_encode(data), Base64.urlsafe_encode(data, false)].each do |encoded|
          io = IO::Memory.new
          Base64.decode(encoded, io).should eq(size)
          io.to_slice.should eq(data)
        end
      end
    end

    it "writes the bytes decoded before an error to the stream" do
      data = Bytes.new(3073) { |i| (i * 31 + 5).to_u8! }
      encoded = Base64.urlsafe_encode(data, false)
      encoded.bytesize.should eq(4098)

      io = IO::Memory.new
      expect_raises(Base64::Error, "Unexpected byte 0x21 at 4098") do
        Base64.decode(encoded + "!!", io)
      end
      io.to_slice.should eq(data[0, 3072])

      io = IO::Memory.new
      expect_raises(Base64::Error, "Wrong size") do
        Base64.decode(encoded[0, 4097], io)
      end
      io.to_slice.should eq(data[0, 3072])
    end

    it "encodes to a stream with an encoding" do
      data = Bytes.new(100) { |i| i.to_u8 }
      io = IO::Memory.new
      io.set_encoding("UTF-16LE")
      Base64.strict_encode(data, io).should eq(136)
      io.to_slice.should eq(Base64.strict_encode(data).encode("UTF-16LE"))
    end
  end

  describe "errors" do
    it "reports the first invalid byte of a group" do
      expect_raises(Base64::Error, "Unexpected byte 0x21 at 1") { Base64.decode("A!B!") }
      expect_raises(Base64::Error, "Unexpected byte 0x0 at 4") { Base64.decode("QUJD\0A") }
      expect_raises(Base64::Error, "Unexpected byte 0x3d at 7") { Base64.decode("QUJDQUI=QUJD") }
      expect_raises(Base64::Error, "Unexpected byte 0xff at 3") { Base64.decode(Bytes[0x41, 0x42, 0x43, 0xff]) }
      expect_raises(Base64::Error, "Unexpected byte 0xa at 7") { Base64.decode("QUJD\n\nA\nBC") }
      expect_raises(Base64::Error, "Unexpected byte 0x2e at 6") { Base64.decode("QUJD\nA.C") }
      expect_raises(Base64::Error, "Unexpected byte 0x2e at 7") { Base64.decode("QUJD\nAB.") }
    end
  end
end
