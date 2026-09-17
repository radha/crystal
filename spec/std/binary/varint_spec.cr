require "spec"
require "binary"

# An IO that reads one byte at a time and never exposes a peek buffer, so
# the byte-by-byte fallback path of `Binary::Varint.decode(T, io)` runs.
private class UnbufferedIO < IO
  def initialize(bytes : Bytes)
    @io = IO::Memory.new(bytes)
  end

  def read(slice : Bytes) : Int32
    return 0 if slice.empty?
    byte = @io.read_byte
    return 0 unless byte
    slice[0] = byte
    1
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end
end

# An IO whose `peek` exposes at most three bytes of what remains, so an
# encoding can be longer than the peek buffer without the IO being at EOF.
private class ShortPeekIO < IO
  def initialize(bytes : Bytes)
    @io = IO::Memory.new(bytes)
  end

  def read(slice : Bytes) : Int32
    @io.read(slice)
  end

  def peek : Bytes?
    rest = @io.peek || Bytes.empty
    rest[0, Math.min(3, rest.size)]
  end

  def skip(bytes_count : Int) : Nil
    @io.skip(bytes_count)
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end
end

private def bytes_of(value) : Bytes
  buffer = Bytes.new(Binary::Varint::MAX_SIZE)
  size = Binary::Varint.encode(value, buffer)
  buffer[0, size]
end

describe Binary::Varint do
  describe ".size" do
    it "counts the bytes of the LEB128 encoding" do
      Binary::Varint.size(0).should eq 1
      Binary::Varint.size(127).should eq 1
      Binary::Varint.size(128).should eq 2
      Binary::Varint.size(16383).should eq 2
      Binary::Varint.size(16384).should eq 3
      Binary::Varint.size(UInt32::MAX).should eq 5
      Binary::Varint.size(UInt64::MAX).should eq 10
    end

    it "sizes negative signed integers as 10 bytes (two's complement)" do
      Binary::Varint.size(-1_i64).should eq 10
      Binary::Varint.size(-1_i32).should eq 10
      Binary::Varint.size(-1_i8).should eq 10
    end
  end

  describe ".encode(value, bytes)" do
    it "writes known encodings and returns the byte count" do
      bytes_of(0).should eq Bytes[0x00]
      bytes_of(1).should eq Bytes[0x01]
      bytes_of(127).should eq Bytes[0x7f]
      bytes_of(128).should eq Bytes[0x80, 0x01]
      bytes_of(300).should eq Bytes[0xac, 0x02]
      bytes_of(16384).should eq Bytes[0x80, 0x80, 0x01]
      bytes_of(UInt32::MAX).should eq Bytes[0xff, 0xff, 0xff, 0xff, 0x0f]
      bytes_of(UInt64::MAX).should eq Bytes[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]
    end

    it "encodes negative signed integers as their 64-bit two's complement" do
      bytes_of(-1_i64).should eq bytes_of(UInt64::MAX)
      bytes_of(-1_i32).should eq bytes_of(UInt64::MAX)
      bytes_of(Int64::MIN).should eq Bytes[0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]
    end

    it "accepts every primitive integer width" do
      bytes_of(5_u8).should eq Bytes[0x05]
      bytes_of(5_i8).should eq Bytes[0x05]
      bytes_of(5_u16).should eq Bytes[0x05]
      bytes_of(5_i16).should eq Bytes[0x05]
      bytes_of(5_u32).should eq Bytes[0x05]
      bytes_of(5_i32).should eq Bytes[0x05]
      bytes_of(5_u64).should eq Bytes[0x05]
      bytes_of(5_i64).should eq Bytes[0x05]
    end

    it "raises IndexError when the buffer is too small" do
      expect_raises(IndexError) { Binary::Varint.encode(128, Bytes.new(1)) }
      expect_raises(IndexError) { Binary::Varint.encode(0, Bytes.empty) }
    end

    it "does not touch bytes past the encoding" do
      buffer = Bytes.new(4, 0xee_u8)
      Binary::Varint.encode(300, buffer).should eq 2
      buffer.should eq Bytes[0xac, 0x02, 0xee, 0xee]
    end
  end

  describe ".encode(value, io)" do
    it "writes the same bytes to an IO and returns the byte count" do
      io = IO::Memory.new
      Binary::Varint.encode(300, io).should eq 2
      Binary::Varint.encode(UInt64::MAX, io).should eq 10
      io.to_slice.should eq Bytes[0xac, 0x02, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]
    end
  end

  describe ".decode(type, bytes)" do
    it "returns the value and the number of bytes consumed" do
      Binary::Varint.decode(UInt64, Bytes[0x00]).should eq({0_u64, 1})
      Binary::Varint.decode(UInt64, Bytes[0x7f]).should eq({127_u64, 1})
      Binary::Varint.decode(UInt64, Bytes[0x80, 0x01]).should eq({128_u64, 2})
      Binary::Varint.decode(UInt64, Bytes[0xac, 0x02]).should eq({300_u64, 2})
      Binary::Varint.decode(UInt64, Bytes[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]).should eq({UInt64::MAX, 10})
    end

    it "ignores bytes after the encoding" do
      Binary::Varint.decode(UInt32, Bytes[0xac, 0x02, 0xff, 0xff]).should eq({300_u32, 2})
    end

    it "decodes into narrower unsigned types" do
      Binary::Varint.decode(UInt8, Bytes[0xff, 0x01]).should eq({255_u8, 2})
      Binary::Varint.decode(UInt16, Bytes[0xff, 0xff, 0x03]).should eq({65535_u16, 3})
      Binary::Varint.decode(UInt32, Bytes[0xff, 0xff, 0xff, 0xff, 0x0f]).should eq({UInt32::MAX, 5})
    end

    it "raises when the value does not fit the unsigned type" do
      expect_raises(Binary::Varint::Error, /UInt8/) { Binary::Varint.decode(UInt8, Bytes[0x80, 0x02]) }
      expect_raises(Binary::Varint::Error, /UInt16/) { Binary::Varint.decode(UInt16, Bytes[0x80, 0x80, 0x04]) }
      expect_raises(Binary::Varint::Error, /UInt32/) { Binary::Varint.decode(UInt32, Bytes[0x80, 0x80, 0x80, 0x80, 0x10]) }
    end

    it "decodes signed types as 64-bit two's complement" do
      minus_one = Bytes[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]
      Binary::Varint.decode(Int64, minus_one).should eq({-1_i64, 10})
      Binary::Varint.decode(Int32, minus_one).should eq({-1_i32, 10})
      Binary::Varint.decode(Int8, minus_one).should eq({-1_i8, 10})
      Binary::Varint.decode(Int64, Bytes[0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]).should eq({Int64::MIN, 10})
      Binary::Varint.decode(Int32, Bytes[0xff, 0xff, 0xff, 0xff, 0x07]).should eq({Int32::MAX, 5})
    end

    it "raises when the value does not fit the signed type" do
      expect_raises(Binary::Varint::Error, /Int32/) { Binary::Varint.decode(Int32, Bytes[0x80, 0x80, 0x80, 0x80, 0x08]) }
      expect_raises(Binary::Varint::Error, /Int8/) { Binary::Varint.decode(Int8, Bytes[0x80, 0x01]) }
      # -2^31 - 1 sign-extended to 64 bits
      too_negative = Bytes[0xff, 0xff, 0xff, 0xff, 0xf7, 0xff, 0xff, 0xff, 0xff, 0x01]
      expect_raises(Binary::Varint::Error, /Int32/) { Binary::Varint.decode(Int32, too_negative) }
    end

    it "raises on a truncated encoding" do
      expect_raises(Binary::Varint::Error, /truncated/i) { Binary::Varint.decode(UInt64, Bytes.empty) }
      expect_raises(Binary::Varint::Error, /truncated/i) { Binary::Varint.decode(UInt64, Bytes[0x80]) }
      expect_raises(Binary::Varint::Error, /truncated/i) { Binary::Varint.decode(UInt64, Bytes[0xff, 0xff, 0xff]) }
    end

    it "raises when the encoding exceeds 64 bits" do
      eleven = Bytes.new(11, 0x80_u8)
      expect_raises(Binary::Varint::Error) { Binary::Varint.decode(UInt64, eleven) }
      tenth_too_big = Bytes[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02]
      expect_raises(Binary::Varint::Error) { Binary::Varint.decode(UInt64, tenth_too_big) }
      ten_continuations = Bytes.new(10, 0x80_u8)
      expect_raises(Binary::Varint::Error) { Binary::Varint.decode(UInt64, ten_continuations) }
    end

    it "accepts non-canonical encodings by default" do
      Binary::Varint.decode(UInt64, Bytes[0x80, 0x00]).should eq({0_u64, 2})
      Binary::Varint.decode(UInt64, Bytes[0x81, 0x80, 0x00]).should eq({1_u64, 3})
    end

    it "rejects non-canonical encodings when strict" do
      expect_raises(Binary::Varint::Error, /canonical/) { Binary::Varint.decode(UInt64, Bytes[0x80, 0x00], strict: true) }
      expect_raises(Binary::Varint::Error, /canonical/) { Binary::Varint.decode(UInt64, Bytes[0x81, 0x80, 0x00], strict: true) }
      Binary::Varint.decode(UInt64, Bytes[0x00], strict: true).should eq({0_u64, 1})
      Binary::Varint.decode(UInt64, Bytes[0x80, 0x01], strict: true).should eq({128_u64, 2})
    end
  end

  describe ".decode?(type, bytes)" do
    it "returns nil on a truncated encoding" do
      Binary::Varint.decode?(UInt64, Bytes.empty).should be_nil
      Binary::Varint.decode?(UInt64, Bytes[0x80]).should be_nil
      Binary::Varint.decode?(UInt64, Bytes[0xff, 0xff, 0xff]).should be_nil
    end

    it "returns the value and byte count otherwise" do
      Binary::Varint.decode?(UInt32, Bytes[0xac, 0x02]).should eq({300_u32, 2})
    end

    it "still raises on malformed encodings" do
      expect_raises(Binary::Varint::Error) { Binary::Varint.decode?(UInt8, Bytes[0x80, 0x02]) }
      expect_raises(Binary::Varint::Error) { Binary::Varint.decode?(UInt64, Bytes.new(11, 0x80_u8)) }
    end
  end

  describe ".decode(type, io)" do
    it "reads from an IO::Memory and leaves the following bytes" do
      io = IO::Memory.new(Bytes[0xac, 0x02, 0x07])
      Binary::Varint.decode(UInt32, io).should eq 300_u32
      io.read_byte.should eq 0x07
      io.read_byte.should be_nil
    end

    it "reads from an IO without a peek buffer" do
      io = UnbufferedIO.new(Bytes[0xac, 0x02, 0x07])
      Binary::Varint.decode(UInt32, io).should eq 300_u32
      io.read_byte.should eq 0x07
    end

    it "reads an encoding longer than the peek buffer" do
      io = ShortPeekIO.new(Bytes[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x07])
      Binary::Varint.decode(UInt64, io).should eq UInt64::MAX
      io.read_byte.should eq 0x07
      io.read_byte.should be_nil
    end

    it "uses the peek buffer when it holds the whole encoding" do
      io = ShortPeekIO.new(Bytes[0xac, 0x02, 0x07])
      Binary::Varint.decode(UInt32, io).should eq 300_u32
      io.read_byte.should eq 0x07
    end

    it "raises IO::EOFError on a truncated encoding" do
      expect_raises(IO::EOFError) { Binary::Varint.decode(UInt64, IO::Memory.new(Bytes.empty)) }
      expect_raises(IO::EOFError) { Binary::Varint.decode(UInt64, IO::Memory.new(Bytes[0x80])) }
      expect_raises(IO::EOFError) { Binary::Varint.decode(UInt64, UnbufferedIO.new(Bytes[0x80, 0x80])) }
    end

    it "raises Binary::Varint::Error on overflow and strict violations" do
      expect_raises(Binary::Varint::Error) { Binary::Varint.decode(UInt8, IO::Memory.new(Bytes[0x80, 0x02])) }
      expect_raises(Binary::Varint::Error) { Binary::Varint.decode(UInt64, IO::Memory.new(Bytes.new(11, 0x80_u8))) }
      expect_raises(Binary::Varint::Error, /canonical/) { Binary::Varint.decode(UInt64, IO::Memory.new(Bytes[0x80, 0x00]), strict: true) }
      expect_raises(Binary::Varint::Error, /canonical/) { Binary::Varint.decode(UInt64, UnbufferedIO.new(Bytes[0x80, 0x00]), strict: true) }
    end
  end

  it "round-trips values of every width through bytes and IO" do
    values = [] of UInt64
    0.upto(64) do |bits|
      base = bits == 64 ? UInt64::MAX : (1_u64 << bits) - 1
      values << base
      values << (base &- 1)
      values << (base &+ 1)
    end
    rng = Random.new(20260917)
    64.times { values << rng.rand(UInt64) }

    values.each do |value|
      buffer = Bytes.new(10)
      size = Binary::Varint.encode(value, buffer)
      size.should eq Binary::Varint.size(value)
      Binary::Varint.decode(UInt64, buffer[0, size], strict: true).should eq({value, size})

      io = IO::Memory.new
      Binary::Varint.encode(value, io).should eq size
      io.rewind
      Binary::Varint.decode(UInt64, io, strict: true).should eq value

      signed = value.to_i64!
      Binary::Varint.encode(signed, buffer).should eq size
      Binary::Varint.decode(Int64, buffer[0, size]).should eq({signed, size})
    end
  end

  describe "zigzag" do
    it "encodes and decodes with .encode_zigzag / .decode_zigzag" do
      bytes = Bytes.new(10)
      Binary::Varint.encode_zigzag(-1_i64, bytes).should eq 1
      bytes[0].should eq 0x01
      Binary::Varint.encode_zigzag(1_i32, bytes).should eq 1
      bytes[0].should eq 0x02
      Binary::Varint.encode_zigzag(-64_i8, bytes).should eq 1
      bytes[0].should eq 0x7f
      Binary::Varint.encode_zigzag(Int32::MIN, bytes).should eq 5
      bytes[0, 5].should eq Bytes[0xff, 0xff, 0xff, 0xff, 0x0f]

      Binary::Varint.decode_zigzag(Int64, Bytes[0x01]).should eq({-1_i64, 1})
      Binary::Varint.decode_zigzag(Int32, Bytes[0xff, 0xff, 0xff, 0xff, 0x0f]).should eq({Int32::MIN, 5})
      Binary::Varint.decode_zigzag(Int32, Bytes[0xfe, 0xff, 0xff, 0xff, 0x0f]).should eq({Int32::MAX, 5})
      Binary::Varint.decode_zigzag(Int64, Bytes[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]).should eq({Int64::MIN, 10})
    end

    it "raises when the zigzag value does not fit the type" do
      expect_raises(Binary::Varint::Error, /Int8/) { Binary::Varint.decode_zigzag(Int8, Bytes[0x80, 0x02]) }
      expect_raises(Binary::Varint::Error, /Int32/) { Binary::Varint.decode_zigzag(Int32, Bytes[0x80, 0x80, 0x80, 0x80, 0x10]) }
    end

    it "works through an IO" do
      io = IO::Memory.new
      Binary::Varint.encode_zigzag(-300_i32, io).should eq 2
      io.rewind
      Binary::Varint.decode_zigzag(Int32, io).should eq -300_i32
    end

    it "round-trips every width" do
      rng = Random.new(7)
      {% for type in [Int8, Int16, Int32, Int64] %}
        [{{type}}::MIN, {{type}}::MAX, {{type}}.zero, {{type}}.new(-1), {{type}}.new(1)].each do |value|
          bytes = Bytes.new(10)
          size = Binary::Varint.encode_zigzag(value, bytes)
          Binary::Varint.decode_zigzag({{type}}, bytes[0, size]).should eq({value, size})
        end
        16.times do
          value = rng.rand({{type}})
          bytes = Bytes.new(10)
          size = Binary::Varint.encode_zigzag(value, bytes)
          Binary::Varint.decode_zigzag({{type}}, bytes[0, size]).should eq({value, size})
        end
      {% end %}
    end
  end
end

describe Binary::Zigzag do
  it "maps signed integers to unsigned of the same width" do
    Binary::Zigzag.encode(0_i32).should eq 0_u32
    Binary::Zigzag.encode(-1_i32).should eq 1_u32
    Binary::Zigzag.encode(1_i32).should eq 2_u32
    Binary::Zigzag.encode(-2_i32).should eq 3_u32
    Binary::Zigzag.encode(Int32::MAX).should eq 4294967294_u32
    Binary::Zigzag.encode(Int32::MIN).should eq 4294967295_u32
    Binary::Zigzag.encode(-1_i8).should eq 1_u8
    Binary::Zigzag.encode(Int8::MIN).should eq 255_u8
    Binary::Zigzag.encode(-1_i16).should eq 1_u16
    Binary::Zigzag.encode(Int64::MIN).should eq UInt64::MAX
    Binary::Zigzag.encode(Int64::MAX).should eq UInt64::MAX - 1
  end

  it "decodes back" do
    Binary::Zigzag.decode(0_u32).should eq 0_i32
    Binary::Zigzag.decode(1_u32).should eq -1_i32
    Binary::Zigzag.decode(2_u32).should eq 1_i32
    Binary::Zigzag.decode(4294967295_u32).should eq Int32::MIN
    Binary::Zigzag.decode(255_u8).should eq Int8::MIN
    Binary::Zigzag.decode(UInt64::MAX).should eq Int64::MIN
    Binary::Zigzag.decode(UInt16::MAX - 1).should eq Int16::MAX
  end
end

describe IO do
  it "#write_varint / #read_varint" do
    io = IO::Memory.new
    io.write_varint(300).should eq 2
    io.write_varint(UInt64::MAX).should eq 10
    io.write_varint(-1_i32).should eq 10
    io.rewind
    io.read_varint.should eq 300_u64
    io.read_varint(UInt64).should eq UInt64::MAX
    io.read_varint(Int32).should eq -1_i32
    expect_raises(IO::EOFError) { io.read_varint }
  end

  it "#write_zigzag / #read_zigzag" do
    io = IO::Memory.new
    io.write_zigzag(-300).should eq 2
    io.write_zigzag(Int64::MIN).should eq 10
    io.rewind
    io.read_zigzag.should eq -300_i64
    io.read_zigzag(Int64).should eq Int64::MIN
    io.rewind
    io.read_zigzag(Int32).should eq -300_i32
  end

  it "#read_varint accepts strict:" do
    io = IO::Memory.new(Bytes[0x80, 0x00])
    expect_raises(Binary::Varint::Error, /canonical/) { io.read_varint(strict: true) }
  end
end
