require "spec"
require "binary"

# Records every `write` call so a spec can count syscall-shaped writes.
private class CountingIO < IO
  getter writes = [] of Bytes

  def read(slice : Bytes) : Int32
    raise IO::Error.new("write-only")
  end

  def write(slice : Bytes) : Nil
    @writes << slice.dup
  end

  def to_slice : Bytes
    io = IO::Memory.new
    @writes.each { |w| io.write(w) }
    io.to_slice
  end
end

# Reads one byte at a time and has no peek buffer.
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

private def framed(body : Bytes, prefix : Binary::Frame::Prefix = :u32_be) : Bytes
  io = IO::Memory.new
  Binary::Frame.write(io, body, prefix: prefix)
  io.to_slice
end

describe Binary::Frame do
  describe ".write" do
    it "prefixes the body with its length as a big-endian UInt32 by default" do
      framed("abc".to_slice).should eq Bytes[0, 0, 0, 3, 'a'.ord, 'b'.ord, 'c'.ord]
    end

    it "writes an empty frame as just the prefix" do
      framed(Bytes.empty).should eq Bytes[0, 0, 0, 0]
    end

    it "supports every prefix kind" do
      body = "abc".to_slice
      framed(body, prefix: :u32_be).should eq Bytes[0, 0, 0, 3, 97, 98, 99]
      framed(body, prefix: :u32_le).should eq Bytes[3, 0, 0, 0, 97, 98, 99]
      framed(body, prefix: :u16_be).should eq Bytes[0, 3, 97, 98, 99]
      framed(body, prefix: :u16_le).should eq Bytes[3, 0, 97, 98, 99]
      framed(body, prefix: :varint).should eq Bytes[3, 97, 98, 99]

      big = Bytes.new(300, 0x61_u8)
      framed(big, prefix: :varint)[0, 3].should eq Bytes[0xac, 0x02, 0x61]
      framed(big, prefix: :u16_be)[0, 3].should eq Bytes[0x01, 0x2c, 0x61]
    end

    it "raises ArgumentError when the body does not fit the prefix" do
      body = Bytes.new(65536)
      expect_raises(ArgumentError, /UInt16/) { framed(body, prefix: :u16_be) }
      expect_raises(ArgumentError, /UInt16/) { framed(body, prefix: :u16_le) }
      framed(body, prefix: :u32_be).size.should eq 65540
      framed(body, prefix: :varint).size.should eq 65539
    end

    it "writes a small frame with a single write call" do
      io = CountingIO.new
      Binary::Frame.write(io, Bytes.new(100, 1_u8))
      io.writes.size.should eq 1
      io.to_slice.should eq framed(Bytes.new(100, 1_u8))
    end

    it "writes a large frame without copying the body" do
      io = CountingIO.new
      body = Bytes.new(1_000_000, 2_u8)
      Binary::Frame.write(io, body)
      io.writes.size.should eq 2
      io.writes[0].should eq Bytes[0x00, 0x0f, 0x42, 0x40]
      io.writes[1].should eq body
    end

    it "builds the body from a block" do
      io = IO::Memory.new
      Binary::Frame.write(io, prefix: :u16_be) do |body|
        body.write_bytes(0x1234_u16, IO::ByteFormat::BigEndian)
        body << "hi"
      end
      io.to_slice.should eq Bytes[0, 4, 0x12, 0x34, 'h'.ord, 'i'.ord]
    end
  end

  describe ".read" do
    it "returns the body of one frame and leaves the rest" do
      io = IO::Memory.new(Bytes[0, 0, 0, 3, 97, 98, 99, 0, 0, 0, 1, 100])
      Binary::Frame.read(io).should eq "abc".to_slice
      Binary::Frame.read(io).should eq "d".to_slice
      io.read_byte.should be_nil
    end

    it "returns an empty slice for an empty frame" do
      Binary::Frame.read(IO::Memory.new(Bytes[0, 0, 0, 0])).should eq Bytes.empty
    end

    it "reads every prefix kind" do
      Binary::Frame.read(IO::Memory.new(Bytes[3, 0, 0, 0, 97, 98, 99]), prefix: :u32_le).should eq "abc".to_slice
      Binary::Frame.read(IO::Memory.new(Bytes[0, 3, 97, 98, 99]), prefix: :u16_be).should eq "abc".to_slice
      Binary::Frame.read(IO::Memory.new(Bytes[3, 0, 97, 98, 99]), prefix: :u16_le).should eq "abc".to_slice
      Binary::Frame.read(IO::Memory.new(Bytes[3, 97, 98, 99]), prefix: :varint).should eq "abc".to_slice

      io = IO::Memory.new
      io.write(Bytes[0xac, 0x02])
      io.write(Bytes.new(300, 7_u8))
      io.rewind
      Binary::Frame.read(io, prefix: :varint).should eq Bytes.new(300, 7_u8)
    end

    it "raises IO::EOFError at end of input" do
      expect_raises(IO::EOFError) { Binary::Frame.read(IO::Memory.new(Bytes.empty)) }
    end

    it "raises IO::EOFError on a truncated prefix" do
      expect_raises(IO::EOFError) { Binary::Frame.read(IO::Memory.new(Bytes[0, 0])) }
      expect_raises(IO::EOFError) { Binary::Frame.read(IO::Memory.new(Bytes[0x80]), prefix: :varint) }
    end

    it "raises IO::EOFError on a truncated body" do
      expect_raises(IO::EOFError) { Binary::Frame.read(IO::Memory.new(Bytes[0, 0, 0, 3, 97])) }
      expect_raises(IO::EOFError) { Binary::Frame.read(UnbufferedIO.new(Bytes[3, 97]), prefix: :varint) }
    end

    it "raises Binary::Frame::TooLargeError instead of allocating an oversized frame" do
      io = IO::Memory.new(Bytes[0x01, 0x00, 0x00, 0x01])
      error = expect_raises(Binary::Frame::TooLargeError) { Binary::Frame.read(io) }
      error.size.should eq 16 * 1024 * 1024 + 1
      error.max_size.should eq Binary::Frame::DEFAULT_MAX_SIZE
      error.message.should match /16777217/

      io = IO::Memory.new(Bytes[0, 0, 0, 5, 1, 2, 3, 4, 5])
      expect_raises(Binary::Frame::TooLargeError) { Binary::Frame.read(io, max_size: 4) }
      Binary::Frame.read(IO::Memory.new(Bytes[0, 0, 0, 5, 1, 2, 3, 4, 5]), max_size: 5).should eq Bytes[1, 2, 3, 4, 5]

      huge = Bytes.new(10, 0xff_u8)
      huge[9] = 0x01
      expect_raises(Binary::Frame::TooLargeError) { Binary::Frame.read(IO::Memory.new(huge), prefix: :varint) }
    end

    it "raises Binary::Varint::Error on a malformed varint prefix" do
      expect_raises(Binary::Varint::Error) { Binary::Frame.read(IO::Memory.new(Bytes.new(11, 0x80_u8)), prefix: :varint) }
    end

    it "reads from an IO without a peek buffer" do
      io = UnbufferedIO.new(Bytes[0, 0, 0, 3, 97, 98, 99, 3, 100, 101, 102])
      Binary::Frame.read(io).should eq "abc".to_slice
      Binary::Frame.read(io, prefix: :varint).should eq "def".to_slice
    end
  end

  describe ".read?" do
    it "returns nil at a clean end of input" do
      Binary::Frame.read?(IO::Memory.new(Bytes.empty)).should be_nil
      Binary::Frame.read?(IO::Memory.new(Bytes.empty), prefix: :varint).should be_nil
      Binary::Frame.read?(UnbufferedIO.new(Bytes.empty)).should be_nil
      Binary::Frame.read?(UnbufferedIO.new(Bytes.empty), prefix: :varint).should be_nil
    end

    it "returns frames until the input ends" do
      io = IO::Memory.new(Bytes[1, 97, 2, 98, 99])
      Binary::Frame.read?(io, prefix: :varint).should eq "a".to_slice
      Binary::Frame.read?(io, prefix: :varint).should eq "bc".to_slice
      Binary::Frame.read?(io, prefix: :varint).should be_nil
    end

    it "still raises IO::EOFError on a truncated prefix or body" do
      expect_raises(IO::EOFError) { Binary::Frame.read?(IO::Memory.new(Bytes[0, 0, 0])) }
      expect_raises(IO::EOFError) { Binary::Frame.read?(IO::Memory.new(Bytes[0, 0, 0, 2, 97])) }
      expect_raises(IO::EOFError) { Binary::Frame.read?(IO::Memory.new(Bytes[0x80]), prefix: :varint) }
      expect_raises(IO::EOFError) { Binary::Frame.read?(UnbufferedIO.new(Bytes[0x80]), prefix: :varint) }
    end
  end

  describe ".read(io, into)" do
    it "replaces the buffer's content with the body and returns its size" do
      buffer = IO::Memory.new
      buffer << "stale content that is longer than the frame"
      io = IO::Memory.new(Bytes[0, 0, 0, 3, 97, 98, 99, 0, 0, 0, 2, 100, 101])

      Binary::Frame.read(io, into: buffer).should eq 3
      buffer.to_slice.should eq "abc".to_slice
      buffer.pos.should eq 0
      buffer.gets_to_end.should eq "abc"

      Binary::Frame.read(io, into: buffer).should eq 2
      buffer.to_slice.should eq "de".to_slice
      buffer.pos.should eq 0
    end

    it "reads a body larger than any internal chunk" do
      body = Bytes.new(100_000) { |i| (i % 251).to_u8 }
      io = IO::Memory.new(framed(body))
      buffer = IO::Memory.new
      Binary::Frame.read(UnbufferedIO.new(io.to_slice), into: buffer).should eq 100_000
      buffer.to_slice.should eq body
    end

    it "raises IO::EOFError on a truncated body" do
      buffer = IO::Memory.new
      expect_raises(IO::EOFError) { Binary::Frame.read(IO::Memory.new(Bytes[0, 0, 0, 3, 97]), into: buffer) }
    end

    it "honours max_size" do
      buffer = IO::Memory.new
      expect_raises(Binary::Frame::TooLargeError) { Binary::Frame.read(IO::Memory.new(Bytes[0, 0, 0, 3, 97, 98, 99]), into: buffer, max_size: 2) }
    end
  end

  describe ".write_prefix / .read_prefix" do
    it "encode and decode just the length" do
      io = IO::Memory.new
      Binary::Frame.write_prefix(300, io, prefix: :varint).should eq 2
      Binary::Frame.write_prefix(300, io, prefix: :u16_le).should eq 2
      Binary::Frame.write_prefix(300, io).should eq 4
      io.to_slice.should eq Bytes[0xac, 0x02, 0x2c, 0x01, 0, 0, 1, 0x2c]
      io.rewind
      Binary::Frame.read_prefix(io, prefix: :varint).should eq 300
      Binary::Frame.read_prefix(io, prefix: :u16_le).should eq 300
      Binary::Frame.read_prefix(io).should eq 300
    end

    it "write_prefix rejects lengths the prefix cannot hold" do
      expect_raises(ArgumentError) { Binary::Frame.write_prefix(65536, IO::Memory.new, prefix: :u16_be) }
      expect_raises(ArgumentError) { Binary::Frame.write_prefix(-1, IO::Memory.new) }
    end

    it "read_prefix enforces max_size" do
      expect_raises(Binary::Frame::TooLargeError) { Binary::Frame.read_prefix(IO::Memory.new(Bytes[0, 0, 0, 9]), max_size: 8) }
    end
  end

  describe "IO extensions" do
    it "round-trips through #write_frame and #read_frame" do
      io = IO::Memory.new
      io.write_frame("hello".to_slice)
      io.write_frame(prefix: :varint) { |body| body << "world" }
      io.write_frame(Bytes.empty)
      io.rewind
      io.read_frame.should eq "hello".to_slice
      io.read_frame(prefix: :varint).should eq "world".to_slice
      io.read_frame.should eq Bytes.empty
      io.read_frame?.should be_nil
      expect_raises(IO::EOFError) { io.read_frame }
    end

    it "#read_frame(into:) reuses a buffer" do
      io = IO::Memory.new
      io.write_frame("hello".to_slice)
      io.rewind
      buffer = IO::Memory.new
      io.read_frame(into: buffer).should eq 5
      buffer.gets_to_end.should eq "hello"
    end

    it "accepts max_size" do
      io = IO::Memory.new
      io.write_frame("hello".to_slice)
      io.rewind
      expect_raises(Binary::Frame::TooLargeError) { io.read_frame(max_size: 4) }
    end

    it "works across a pipe" do
      IO.pipe do |reader, writer|
        spawn do
          writer.write_frame("ping".to_slice)
          writer.write_frame(Bytes.new(70_000, 9_u8), prefix: :varint)
          writer.flush
        end
        reader.read_frame.should eq "ping".to_slice
        reader.read_frame(prefix: :varint).should eq Bytes.new(70_000, 9_u8)
      end
    end
  end
end
