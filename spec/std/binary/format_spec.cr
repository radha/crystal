# spec/std/binary/format_spec.cr
require "spec"
require "binary"

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
end
