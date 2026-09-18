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

# Records every `write` and `read` call so a spec can count syscall-shaped IO.
private class CountingIO < IO
  getter writes = [] of Bytes
  getter reads = 0

  def initialize(@input : Bytes = Bytes.empty)
    @pos = 0
  end

  def read(slice : Bytes) : Int32
    @reads += 1
    n = Math.min(slice.size, @input.size - @pos)
    slice.copy_from(@input.to_unsafe + @pos, n)
    @pos += n
    n
  end

  def write(slice : Bytes) : Nil
    @writes << slice.dup
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

private struct Ipv4
  include Binary::Format
  field version : UInt8, bits: 4
  field ihl : UInt8, bits: 4
  field dscp : UInt8, bits: 6
  field ecn : UInt8, bits: 2
  field total_length : UInt16
  field id : UInt16
  field reserved : Bool, bits: 1
  field df : Bool, bits: 1
  field mf : Bool, bits: 1
  field fragment_offset : UInt16, bits: 13
end

private struct LsbBits
  include Binary::Format
  bit_order :lsb
  field kind : Kind, bits: 3
  field a : UInt16, bits: 9
  field b : UInt8, bits: 4
end

private struct Elf64Ident
  include Binary::Format
  endian :little
  magic Bytes[0x7F, 0x45, 0x4C, 0x46]
  field class_ : UInt8
  field data : UInt8
  field version : UInt8
  field osabi : UInt8
  field abiversion : UInt8
  pad 7
  field type : UInt16
  field machine : UInt16
  field e_version : UInt32
  field entry : UInt64
  field name : String, length: 4
  field tags : StaticArray(UInt16, 2)
  field point : Point
  field kinds : Array(Kind), count: 2
end

private struct SizedFixed
  include Binary::Format
  field len : UInt32, size_of: :rest
  field a : UInt16
  field b : UInt8
end

private struct PgQuery
  include Binary::Format
  field type : UInt8 = 'Q'.ord.to_u8
  field length : Int32, size_of: :rest, including_self: true
  field query : String, cstring: true
end

private struct PgFieldDesc
  include Binary::Format
  field name : String, cstring: true
  field table_oid : Int32
  field column : Int16
  field type_oid : Int32
  field type_size : Int16
  field type_modifier : Int32
  field format_code : Int16
end

private struct PgRowDescription
  include Binary::Format
  field type : UInt8 = 'T'.ord.to_u8
  field length : Int32, size_of: :rest, including_self: true
  field count : Int16
  field fields : Array(PgFieldDesc), count: :count
end

private struct PgColumn
  include Binary::Format
  field length : Int32
  field value : Bytes?, length: :length, if: -> { length >= 0 }
end

private struct PgDataRow
  include Binary::Format
  field type : UInt8 = 'D'.ord.to_u8
  field length : Int32, size_of: :rest, including_self: true
  field count : Int16
  field columns : Array(PgColumn), count: :count
end

private struct RpcFrameHeader
  include Binary::Format
  field type : UInt8
  field flags : UInt8
  field stream_id : UInt32
  field length : UInt32
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

  describe "bits" do
    it "packs MSB-first runs like an IPv4 header" do
      h = Ipv4.new(version: 4, ihl: 5, dscp: 0, ecn: 0, total_length: 60, id: 0x1C46, reserved: false, df: true, mf: false, fragment_offset: 0)
      h.to_slice.should eq Bytes[0x45, 0x00, 0x00, 0x3C, 0x1C, 0x46, 0x40, 0x00]
      h.byte_size.should eq 8
      back = Ipv4.from_slice(h.to_slice)
      back.should eq h
      back.df.should be_true
    end

    it "packs LSB-first runs" do
      v = LsbBits.new(kind: :response, a: 0x1AB, b: 0xC)
      # bits 0..2 = 2, bits 3..11 = 0x1AB, bits 12..15 = 0xC
      # value = 2 | (0x1AB << 3) | (0xC << 12) = 0xCD5A -> little-endian bytes 5A CD
      v.to_slice.should eq Bytes[0x5A, 0xCD]
      LsbBits.from_slice(v.to_slice).should eq v
    end

    it "raises on write when a value is wider than its bit field" do
      expect_raises(Binary::Format::Error, /Ipv4#version/) do
        Ipv4.new(version: 16, ihl: 5, dscp: 0, ecn: 0, total_length: 0, id: 0, reserved: false, df: false, mf: false, fragment_offset: 0).to_slice
      end
    end
  end

  describe "fixed layouts" do
    it "exposes SIZE and fixed_size? only for fixed layouts" do
      Header.fixed_size?.should be_true
      Header::SIZE.should eq 10
      Ipv4::SIZE.should eq 8
      PngSig::SIZE.should eq 20
      Aligned::SIZE.should eq 16
      Elf64Ident::SIZE.should eq 16 + 2 + 2 + 4 + 8 + 4 + 4 + 4 + 2
      Texts.fixed_size?.should be_false
      Shapes.fixed_size?.should be_false
      Startup.fixed_size?.should be_false
      Varints.fixed_size?.should be_false
    end

    it "decodes by pointer and encodes with write_to" do
      e = Elf64Ident.new(class_: 2, data: 1, version: 1, osabi: 0, abiversion: 0, type: 2, machine: 0x3E, e_version: 1, entry: 0x401000,
        name: "abcd", tags: StaticArray[1_u16, 2_u16], point: Point.new(x: -1, y: 1), kinds: [Kind::Request, Kind::Response])
      bytes = e.to_slice
      bytes.size.should eq Elf64Ident::SIZE
      bytes[0, 4].should eq Bytes[0x7F, 0x45, 0x4C, 0x46]
      bytes[16, 2].should eq Bytes[2, 0]
      bytes[24, 8].should eq Bytes[0x00, 0x10, 0x40, 0, 0, 0, 0, 0]
      bytes[32, 4].should eq "abcd".to_slice
      bytes[36, 4].should eq Bytes[1, 0, 2, 0]
      bytes[40, 4].should eq Bytes[0xFF, 0xFF, 0, 1]
      bytes[44, 2].should eq Bytes[1, 2]
      Elf64Ident.from_slice(bytes).should eq e
      buf = Bytes.new(Elf64Ident::SIZE + 3)
      e.write_to(buf).should eq Elf64Ident::SIZE
      buf[0, Elf64Ident::SIZE].should eq bytes
      Elf64Ident.from_slice(Bytes[0, 0] + bytes, 2).should eq({e, Elf64Ident::SIZE})
    end

    it "reads and writes a fixed record with a single IO call" do
      h = Header.new(kind: :request, flags: 1, stream_id: 2, length: 3)
      io = CountingIO.new
      h.write(io)
      io.writes.size.should eq 1
      io.writes[0].should eq h.to_slice
      input = CountingIO.new(h.to_slice)
      Header.read(input).should eq h
      input.reads.should eq 1
    end

    it "raises IO::EOFError from from_slice and write_to on short buffers" do
      expect_raises(IO::EOFError) { Header.from_slice(Bytes.new(9)) }
      expect_raises(IO::EOFError) { Header.from_slice(Bytes.new(12), 3) }
      expect_raises(ArgumentError) { Header.new(kind: :request, flags: 0, stream_id: 0).write_to(Bytes.new(9)) }
      expect_raises(Binary::Format::MagicError) { Elf64Ident.from_slice(Bytes.new(Elf64Ident::SIZE)) }
    end

    it "checks fixed-length strings and counts on write_to" do
      e = Elf64Ident.new(class_: 0, data: 0, version: 0, osabi: 0, abiversion: 0, type: 0, machine: 0, e_version: 0, entry: 0,
        name: "abc", tags: StaticArray[0_u16, 0_u16], point: Point.new(x: 0, y: 0), kinds: [Kind::Request, Kind::Request])
      expect_raises(Binary::Format::Error, /Elf64Ident#name/) { e.to_slice }
    end
  end

  describe "size_of with fixed tail" do
    it "treats a size_of layout with a fixed tail as variable" do
      SizedFixed.fixed_size?.should be_false
      s = SizedFixed.new(a: 0x0102, b: 3)
      s.to_slice.should eq Bytes[0, 0, 0, 3, 1, 2, 3]
      s.len.should eq 3
      SizedFixed.from_slice(s.to_slice).should eq s
    end
  end

  describe "known-answer dumps" do
    it "Postgres Query" do
      q = PgQuery.new(query: "select 1")
      q.to_slice.should eq Bytes[0x51, 0, 0, 0, 13] + "select 1\0".to_slice
      PgQuery.from_slice(q.to_slice).query.should eq "select 1"
    end

    it "Postgres RowDescription" do
      rd = PgRowDescription.new(fields: [
        PgFieldDesc.new(name: "id", table_oid: 16384, column: 1, type_oid: 23, type_size: 4, type_modifier: -1, format_code: 1),
      ])
      bytes = rd.to_slice
      bytes[0].should eq 'T'.ord
      IO::ByteFormat::BigEndian.decode(Int32, bytes[1, 4]).should eq bytes.size - 1
      bytes[5, 2].should eq Bytes[0, 1]
      bytes[7, 3].should eq "id\0".to_slice
      back = PgRowDescription.from_slice(bytes)
      back.fields.size.should eq 1
      back.fields[0].type_modifier.should eq -1
      back.fields[0].format_code.should eq 1
    end

    it "Postgres DataRow with a NULL column" do
      # `PgColumn#length` is derived from `value` (`value.try(&.size) || 0`),
      # so a `nil` value always derives a length of 0, not the wire's `-1`
      # NULL sentinel. `PgColumn#value`'s `if: -> { length >= 0 }` then sees
      # that derived 0 and considers the field present, so writing a `nil`
      # value raises the same `if:`-was-true-but-the-field-is-nil error as
      # `Optional#extra` does (see the "varint, if, value and size_of"
      # describe block above) instead of silently emitting a 0-length,
      # no-data column. This matches the module docs: a real client writes
      # NULL columns (the `-1` wire form) through its own encoder, not
      # through this derived length/`if:` combination.
      expect_raises(Binary::Format::Error, /PgColumn#value/) do
        PgDataRow.new(columns: [PgColumn.new(value: "42".to_slice), PgColumn.new(value: nil)]).to_slice
      end

      one_column = PgDataRow.new(columns: [PgColumn.new(value: "42".to_slice)])
      bytes = one_column.to_slice
      bytes.should eq Bytes[0x44, 0, 0, 0, 12, 0, 1, 0, 0, 0, 2, 0x34, 0x32]
      IO::ByteFormat::BigEndian.decode(Int32, bytes[1, 4]).should eq bytes.size - 1

      null = Bytes[0x44, 0, 0, 0, 16, 0, 2, 0, 0, 0, 2, 0x34, 0x32, 0xFF, 0xFF, 0xFF, 0xFF]
      back = PgDataRow.from_slice(null)
      back.columns[0].value.should eq "42".to_slice
      back.columns[1].value.should be_nil
      back.columns[1].length.should eq -1
    end

    it "RPC frame header is a 10-byte fixed layout" do
      RpcFrameHeader::SIZE.should eq 10
      h = RpcFrameHeader.new(type: 1, flags: 0x80, stream_id: 7, length: 512)
      h.to_slice.should eq Bytes[1, 0x80, 0, 0, 0, 7, 0, 0, 2, 0]
      RpcFrameHeader.from_slice(h.to_slice).should eq h
    end
  end

  describe "random round-trips" do
    it "fixed layouts survive 1000 random instances" do
      rng = Random.new(7)
      1000.times do
        h = Ipv4.new(version: rng.rand(16).to_u8, ihl: rng.rand(16).to_u8, dscp: rng.rand(64).to_u8, ecn: rng.rand(4).to_u8,
          total_length: rng.rand(UInt16), id: rng.rand(UInt16), reserved: rng.next_bool, df: rng.next_bool, mf: rng.next_bool,
          fragment_offset: rng.rand(8192).to_u16)
        Ipv4.from_slice(h.to_slice).should eq h
        m = Mixed.new(a: rng.rand(Int16), b: rng.next_float.to_f32, c: rng.next_bool, d: rng.rand(UInt64))
        Mixed.from_slice(m.to_slice).should eq m
      end
    end

    it "variable layouts survive 300 random instances through IO and slices" do
      rng = Random.new(11)
      300.times do
        params = Array.new(rng.rand(0..5)) { rng.hex(rng.rand(0..8)) }
        s = Startup.new(params: params)
        Startup.from_slice(s.to_slice).should eq s
        Startup.read(IO::Memory.new(s.to_slice)).should eq s
        v = Varints.new(a: rng.rand(UInt32), b: rng.rand(Int64), k: rng.next_bool ? Kind::Request : Kind::Response, xs: [rng.rand(Int32), rng.rand(Int32)])
        Varints.from_slice(v.to_slice).should eq v
        t = Texts.new(name: rng.hex(rng.rand(0..10)), tag: rng.hex(2), note: rng.hex(rng.rand(0..4)), n: rng.rand(4).to_u8,
          twice: Bytes.new(0), rest: Bytes.new(rng.rand(0..6)) { rng.rand(UInt8) })
        t = Texts.new(name: t.name, tag: t.tag, note: t.note, n: t.n, twice: Bytes.new((t.n * 2).to_i32) { rng.rand(UInt8) }, rest: t.rest)
        Texts.from_slice(t.to_slice).should eq t
      end
    end
  end
end
