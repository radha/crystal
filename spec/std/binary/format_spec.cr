# spec/std/binary/format_spec.cr
require "spec"
require "binary"

# Reads one byte at a time and has no peek buffer.
private class UnbufferedIO < IO
  def initialize(@bytes : Bytes)
    @pos = 0
  end

  def read(slice : Bytes) : Int32
    return 0 if @pos >= @bytes.size || slice.empty?
    slice[0] = @bytes[@pos]
    @pos += 1
    1
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end
end

private enum Kind : UInt8
  Request  = 1
  Response = 2
end

private struct Header
  include Binary::Format
  field kind : Kind
  field flags : UInt8
  field stream_id : UInt32
  field length : UInt32 = 0
end

private struct Mixed
  include Binary::Format
  endian :little
  field a : Int16
  field b : Float32, endian: :big
  field c : Bool
  field d : UInt64
end

private struct PngSig
  include Binary::Format
  magic Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  field width : UInt32
  field height : UInt32
  field depth : UInt8
  pad 3
end

private struct Riff
  include Binary::Format
  endian :little
  magic "RIFF"
  field size : UInt32
  magic 0xCAFEBABE_u32
end

private struct Aligned
  include Binary::Format
  field a : UInt8
  align 4
  field b : UInt32
  field c : UInt8
  align 8
end

private enum Signed16 : Int16
  Neg = -2
  Pos =  3
end

private struct SignedEnum
  include Binary::Format
  field s : Signed16
  field t : Signed16, endian: :little
end

private struct Texts
  include Binary::Format
  field name_len : UInt8
  field name : String, length: :name_len
  field tag : String, length: 4
  field note : String, cstring: true
  field n : UInt8
  field twice : Bytes, length: -> { n * 2 }
  field rest : Bytes, until: :eof
end

private struct Capped
  include Binary::Format
  field len : UInt32
  field body : Bytes, length: :len, max: 8
end

private struct Point
  include Binary::Format
  field x : Int16
  field y : Int16
end

private struct Shapes
  include Binary::Format
  field count : UInt16
  field points : Array(Point), count: :count, max: 100
  field ident : StaticArray(UInt8, 4)
  field names : Array(String), cstring: true, sentinel: ""
  field tail : Array(UInt32), until: :eof, endian: :little
end

private struct FixedCounts
  include Binary::Format
  field pair : Array(UInt8), count: 2
  field n : UInt8
  field more : Array(UInt16), count: -> { n + 1 }
end

private struct FixedElems
  include Binary::Format
  field chunks : StaticArray(Bytes, 2), length: 2
  field tags : Array(String), length: 3, count: 2
end

private struct Startup
  include Binary::Format
  field length : Int32, size_of: :rest, including_self: true
  field version : Int32 = 196608
  field params : Array(String), cstring: true, until: :eof
end

private struct Optional
  include Binary::Format
  field flags : UInt8
  field extra : UInt16?, if: -> { flags & 1 != 0 }
  field name : String?, cstring: true, if: -> { flags & 2 != 0 }
  field n : UInt8, value: -> { flags &+ 1 }
end

private struct Varints
  include Binary::Format
  field a : UInt32, varint: true
  field b : Int64, varint: true
  field k : Kind, varint: true
  field xs : Array(Int32), count: 2, varint: true
end

describe Binary::Format do
  describe "scalars" do
    it "writes big-endian by default and reads back" do
      h = Header.new(kind: :response, flags: 3, stream_id: 0x01020304, length: 7)
      bytes = h.to_slice
      bytes.should eq Bytes[2, 3, 1, 2, 3, 4, 0, 0, 0, 7]
      h.byte_size.should eq 10
      back = Header.read(IO::Memory.new(bytes))
      back.kind.should eq Kind::Response
      back.flags.should eq 3
      back.stream_id.should eq 0x01020304
      back.length.should eq 7
      Header.from_slice(bytes).should eq back
      Header.from_slice(Bytes[0xFF] + bytes, 1).should eq({back, 10})
    end

    it "honours defaults and setters" do
      h = Header.new(kind: :request, flags: 0, stream_id: 1)
      h.length.should eq 0
      h.length = 9
      h.length.should eq 9
    end

    it "uses the type endian with per-field overrides" do
      m = Mixed.new(a: -2, b: 1.5_f32, c: true, d: 0x0102030405060708)
      m.to_slice.should eq Bytes[0xFE, 0xFF, 0x3F, 0xC0, 0, 0, 1, 8, 7, 6, 5, 4, 3, 2, 1]
      back = Mixed.from_slice(m.to_slice)
      back.should eq m
      back.c.should be_true
    end

    it "raises IO::EOFError on truncated input" do
      expect_raises(IO::EOFError) { Header.from_slice(Bytes[2, 3, 1]) }
    end

    it "writes to an IO" do
      io = IO::Memory.new
      Mixed.new(a: 1, b: 0_f32, c: false, d: 0).write(io)
      io.to_slice.size.should eq 15
    end

    it "round-trips enums with a signed base type" do
      v = SignedEnum.new(s: :neg, t: :pos)
      v.to_slice.should eq Bytes[0xFF, 0xFE, 3, 0]
      SignedEnum.from_slice(v.to_slice).should eq v
    end
  end

  describe "pad, align and magic" do
    it "writes magic bytes and zero padding" do
      png = PngSig.new(width: 1, height: 2, depth: 8)
      png.to_slice.should eq Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1, 0, 0, 0, 2, 8, 0, 0, 0]
      png.byte_size.should eq 20
      PngSig.from_slice(png.to_slice).should eq png
    end

    it "accepts String and suffixed integer magics in the type endian" do
      r = Riff.new(size: 4)
      r.to_slice.should eq Bytes[0x52, 0x49, 0x46, 0x46, 4, 0, 0, 0, 0xBE, 0xBA, 0xFE, 0xCA]
      Riff.from_slice(r.to_slice).size.should eq 4
    end

    it "raises MagicError naming both byte strings" do
      bad = Bytes[0x89, 0x50, 0x4E, 0x48, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1, 0, 0, 0, 2, 8, 0, 0, 0]
      ex = expect_raises(Binary::Format::MagicError) { PngSig.from_slice(bad) }
      ex.message.not_nil!.should contain "89504e470d0a1a0a"
      ex.message.not_nil!.should contain "89504e480d0a1a0a"
    end

    it "aligns relative to the start of the record" do
      a = Aligned.new(a: 1, b: 2, c: 3)
      a.to_slice.should eq Bytes[1, 0, 0, 0, 0, 0, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0]
      a.byte_size.should eq 16
      Aligned.from_slice(a.to_slice).should eq a
    end

    it "skips padding bytes on read regardless of their content" do
      bytes = Bytes[1, 9, 9, 9, 0, 0, 0, 2, 3, 9, 9, 9, 9, 9, 9, 9]
      Aligned.from_slice(bytes).should eq Aligned.new(a: 1, b: 2, c: 3)
    end
  end

  describe "String and Bytes" do
    it "derives length fields and round-trips every mode" do
      t = Texts.new(name: "abc", tag: "TAG!", note: "hi", n: 2, twice: Bytes[7, 8, 9, 10], rest: Bytes[1, 2])
      t.name_len.should eq 3
      t.to_slice.should eq Bytes[3, 0x61, 0x62, 0x63, 0x54, 0x41, 0x47, 0x21, 0x68, 0x69, 0, 2, 7, 8, 9, 10, 1, 2]
      t.byte_size.should eq 18
      back = Texts.from_slice(t.to_slice)
      back.should eq t
      back.name_len.should eq 3
    end

    it "reads the rest through an IO::Memory and an unbuffered IO" do
      bytes = Texts.new(name: "", tag: "abcd", note: "", n: 0, twice: Bytes.empty, rest: Bytes[5, 6, 7]).to_slice
      Texts.read(IO::Memory.new(bytes)).rest.should eq Bytes[5, 6, 7]
      Texts.read(UnbufferedIO.new(bytes)).rest.should eq Bytes[5, 6, 7]
    end

    it "raises SizeError beyond max: and on negative lengths" do
      bytes = Bytes[0, 0, 0, 9, 1, 2, 3, 4, 5, 6, 7, 8, 9]
      expect_raises(Binary::Format::SizeError, /Capped#body/) { Capped.from_slice(bytes) }
      Capped.from_slice(Bytes[0, 0, 0, 2, 1, 2]).body.should eq Bytes[1, 2]
    end

    it "raises on a NUL inside a cstring and on a wrong fixed length" do
      expect_raises(Binary::Format::Error, /Texts#note/) do
        Texts.new(name: "", tag: "abcd", note: "a\0b", n: 0, twice: Bytes.empty, rest: Bytes.empty).to_slice
      end
      expect_raises(Binary::Format::Error, /Texts#tag/) do
        Texts.new(name: "", tag: "abc", note: "", n: 0, twice: Bytes.empty, rest: Bytes.empty).to_slice
      end
      expect_raises(Binary::Format::Error, /Texts#twice/) do
        Texts.new(name: "", tag: "abcd", note: "", n: 1, twice: Bytes[1, 2, 3], rest: Bytes.empty).to_slice
      end
    end

    it "raises IO::EOFError on an unterminated cstring" do
      expect_raises(IO::EOFError) { Texts.from_slice(Bytes[0, 0x54, 0x41, 0x47, 0x21, 0x68, 0x69]) }
    end
  end

  describe "Array, StaticArray and nested formats" do
    it "round-trips count-prefixed, sentinel-terminated and rest arrays" do
      s = Shapes.new(
        points: [Point.new(x: 1, y: -1), Point.new(x: 2, y: -2)],
        ident: StaticArray[9_u8, 8_u8, 7_u8, 6_u8],
        names: ["ab", "c"],
        tail: [1_u32, 2_u32],
      )
      s.count.should eq 2
      s.to_slice.should eq Bytes[
        0, 2, 0, 1, 0xFF, 0xFF, 0, 2, 0xFF, 0xFE,
        9, 8, 7, 6,
        0x61, 0x62, 0, 0x63, 0, 0,
        1, 0, 0, 0, 2, 0, 0, 0,
      ]
      s.byte_size.should eq 28
      back = Shapes.from_slice(s.to_slice)
      back.should eq s
      back.count.should eq 2
    end

    it "checks literal and computed counts on write" do
      f = FixedCounts.new(pair: [1_u8, 2_u8], n: 1, more: [3_u16, 4_u16])
      f.to_slice.should eq Bytes[1, 2, 1, 0, 3, 0, 4]
      FixedCounts.from_slice(f.to_slice).should eq f
      expect_raises(Binary::Format::Error, /FixedCounts#pair/) do
        FixedCounts.new(pair: [1_u8], n: 0, more: [] of UInt16).to_slice
      end
      expect_raises(Binary::Format::Error, /FixedCounts#more/) do
        FixedCounts.new(pair: [1_u8, 2_u8], n: 0, more: [] of UInt16).to_slice
      end
    end

    it "raises SizeError for a count beyond max:" do
      expect_raises(Binary::Format::SizeError, /Shapes#points/) do
        Shapes.from_slice(Bytes[0xFF, 0xFF] + Bytes.new(4))
      end
    end

    it "requires a peekable IO for until: :eof arrays" do
      bytes = Shapes.new(points: [] of Point, ident: StaticArray[0_u8, 0_u8, 0_u8, 0_u8], names: [] of String, tail: [7_u32]).to_slice
      Shapes.read(IO::Memory.new(bytes)).tail.should eq [7_u32]
      expect_raises(Binary::Format::Error, /peek/) { Shapes.read(UnbufferedIO.new(bytes)) }
    end

    it "reads and writes fixed-length String and Bytes elements" do
      f = FixedElems.new(chunks: StaticArray[Bytes[1, 2], Bytes[3, 4]], tags: ["abc", "def"])
      f.to_slice.should eq Bytes[1, 2, 3, 4, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66]
      f.byte_size.should eq 10
      FixedElems.from_slice(f.to_slice).should eq f
      expect_raises(Binary::Format::Error, /FixedElems#tags/) do
        FixedElems.new(chunks: StaticArray[Bytes[1, 2], Bytes[3, 4]], tags: ["ab", "def"]).to_slice
      end
    end
  end

  describe "varint, if, value and size_of" do
    it "encodes the Postgres StartupMessage with a derived total length" do
      s = Startup.new(params: ["user", "bob", "database", "db", ""])
      s.to_slice.should eq Bytes[0, 0, 0, 30, 0, 3, 0, 0] + "user\0bob\0database\0db\0\0".to_slice
      s.length.should eq 30
      s.byte_size.should eq 30
      back = Startup.from_slice(s.to_slice)
      back.params.should eq ["user", "bob", "database", "db", ""]
      back.length.should eq 30
      back.version.should eq 196608
    end

    it "bounds the rest of the record with size_of so trailing bytes are untouched" do
      bytes = Startup.new(params: ["a"]).to_slice + Bytes[0xAA, 0xBB]
      io = IO::Memory.new(bytes)
      Startup.read(io).params.should eq ["a"]
      io.read_byte.should eq 0xAA
    end

    it "raises SizeError on a negative or oversized size_of" do
      expect_raises(Binary::Format::SizeError) { Startup.from_slice(Bytes[0xFF, 0xFF, 0xFF, 0xFF]) }
    end

    it "reads and writes optional fields by condition" do
      Optional.new(flags: 0).to_slice.should eq Bytes[0, 1]
      Optional.new(flags: 3, extra: 7, name: "x").to_slice.should eq Bytes[3, 0, 7, 0x78, 0, 4]
      o = Optional.from_slice(Bytes[1, 0, 9, 2])
      o.extra.should eq 9
      o.name.should be_nil
      o.n.should eq 2
      Optional.from_slice(Bytes[2, 0x79, 0, 3]).name.should eq "y"
    end

    it "raises when a required conditional field is nil and skips it when the condition is false" do
      expect_raises(Binary::Format::Error, /Optional#extra/) { Optional.new(flags: 1).to_slice }
      Optional.new(flags: 0, extra: 5).to_slice.should eq Bytes[0, 1]
    end

    it "computes value: fields on construction and on write" do
      Optional.new(flags: 4).n.should eq 5
      o = Optional.new(flags: 4)
      o.flags = 8
      o.to_slice.should eq Bytes[8, 9]
    end

    it "encodes varints, zigzag for signed types and enums" do
      v = Varints.new(a: 300, b: -1, k: :response, xs: [-2, 150])
      v.to_slice.should eq Bytes[0xAC, 0x02, 0x01, 0x02, 0x03, 0xAC, 0x02]
      v.byte_size.should eq 7
      Varints.from_slice(v.to_slice).should eq v
    end
  end
end
