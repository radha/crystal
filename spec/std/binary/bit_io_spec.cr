require "spec"
require "binary"

describe Binary::BitReader do
  it "reads MSB-first fields byte-exactly" do
    # 0b101_00011 0b11110000 -> 3 bits = 5, 5 bits = 3, 4 bits = 15, 4 bits = 0
    r = Binary::BitReader.new(Bytes[0b1010_0011, 0b1111_0000])
    r.read_bits(3).should eq 5
    r.read_bits(5).should eq 3
    r.read_bits(4).should eq 15
    r.read_bits(4).should eq 0
    r.eof?.should be_true
  end

  it "reads LSB-first fields byte-exactly (deflate order)" do
    # byte 0 = 0b1010_0011: low 3 bits = 3, next 5 bits = 0b10100 = 20
    r = Binary::BitReader.new(Bytes[0b1010_0011, 0b1111_0000], :lsb)
    r.read_bits(3).should eq 3
    r.read_bits(5).should eq 20
    r.read_bits(4).should eq 0
    r.read_bits(4).should eq 15
  end

  it "reads 64 bits after an unaligned prefix (refill split)" do
    bytes = Bytes[0xF0, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
    r = Binary::BitReader.new(bytes)
    r.read_bits(4).should eq 0xF
    r.read_bits(64).should eq 0x00123456789ABCDE_u64
    r.read_bits(4).should eq 0xF
    r.eof?.should be_true
  end

  it "uses the 8-byte refill path on long slices" do
    bytes = Bytes.new(24) { |i| (i * 37).to_u8! }
    r = Binary::BitReader.new(bytes)
    expected = IO::ByteFormat::BigEndian.decode(UInt64, bytes[0, 8])
    r.read_bits(64).should eq expected
    r.read_bits(8).should eq bytes[8]
    r.read_bits(64).should eq IO::ByteFormat::BigEndian.decode(UInt64, bytes[9, 8])
  end

  it "reads 64 bits when 60 bits are already buffered" do
    bytes = Bytes.new(16) { |i| (0x11 * (i + 1)).to_u8! }
    r = Binary::BitReader.new(bytes)
    r.read_bits(4).should eq 1
    expected = (IO::ByteFormat::BigEndian.decode(UInt64, bytes[0, 8]) << 4) | (bytes[8].to_u64 >> 4)
    r.read_bits(64).should eq expected
    r2 = Binary::BitReader.new(bytes, :lsb)
    r2.read_bits(4).should eq 1
    expected2 = (IO::ByteFormat::LittleEndian.decode(UInt64, bytes[0, 8]) >> 4) | (bytes[8].to_u64 << 60)
    r2.read_bits(64).should eq expected2
  end

  it "reads 0 bits as 0 without consuming" do
    r = Binary::BitReader.new(Bytes[0xFF])
    r.read_bits(0).should eq 0
    r.bit_position.should eq 0
  end

  it "reports bit_position and aligns" do
    r = Binary::BitReader.new(Bytes[0xAB, 0xCD])
    r.read_bits(3)
    r.bit_position.should eq 3
    r.align!
    r.bit_position.should eq 8
    r.read_bits(8).should eq 0xCD
    r.align!
    r.bit_position.should eq 16
  end

  it "returns nil from read_bits? and raises from read_bits at end of data" do
    r = Binary::BitReader.new(Bytes[0x01])
    r.read_bits(4).should eq 0
    r.read_bits?(8).should be_nil
    expect_raises(IO::EOFError) { r.read_bits(8) }
    r.read_bits(4).should eq 1
  end

  it "rejects widths outside 0..64" do
    r = Binary::BitReader.new(Bytes[0x01])
    expect_raises(ArgumentError) { r.read_bits(65) }
    expect_raises(ArgumentError) { r.read_bits(-1) }
  end

  it "reads from an IO" do
    r = Binary::BitReader.new(IO::Memory.new(Bytes[0b1010_0011, 0xFF]))
    r.read_bits(3).should eq 5
    r.read_bits(13).should eq 0b00011_11111111
    r.eof?.should be_true
  end

  it "returns nil from read_bits? on a short IO without consuming buffered bits" do
    io = IO::Memory.new(Bytes[0xAB, 0xCD])
    r = Binary::BitReader.new(io)
    r.read_bits(4).should eq 0xA
    r.read_bits?(16).should be_nil
    r.bit_position.should eq 4
    r.read_bits(12).should eq 0xBCD
    r.eof?.should be_true
    r.read_bits?(1).should be_nil
  end

  it "reports eof? correctly on an IO with staged bytes" do
    r = Binary::BitReader.new(IO::Memory.new(Bytes[0x80]))
    r.eof?.should be_false
    r.read_bit.should be_true
    r.eof?.should be_false
    r.read_bits(7).should eq 0
    r.eof?.should be_true
  end

  it "compacts the staging buffer across a short read followed by more data" do
    # IO::Memory.new(bytes) wraps the slice non-resizeably, so a later
    # `write` would raise; build a resizeable IO::Memory and rewind it to
    # read from the start instead.
    io = IO::Memory.new
    io.write(Bytes[1, 2, 3, 4, 5, 6, 7])
    io.rewind
    r = Binary::BitReader.new(io)
    r.read_bits?(60).should be_nil
    r.read_bits(8).should eq 1
    r.read_bits(8).should eq 2
    io.write(Bytes[8, 9, 10, 11, 12, 13, 14, 15])
    io.pos = 7
    r.read_bits(64).should eq IO::ByteFormat::BigEndian.decode(UInt64, Bytes[3, 4, 5, 6, 7, 8, 9, 10])
    r.read_bits(40).should eq IO::ByteFormat::BigEndian.decode(UInt64, Bytes[0, 0, 0, 11, 12, 13, 14, 15])
    r.eof?.should be_true
  end

  it "reads LSB-first from an IO across several refills" do
    bytes = Bytes.new(24) { |i| (i * 53).to_u8! }
    r = Binary::BitReader.new(IO::Memory.new(bytes), :lsb)
    expected = IO::ByteFormat::LittleEndian.decode(UInt64, bytes[0, 8])
    r.read_bits(3).should eq(expected & 0x7)
    r.read_bits(61).should eq(expected >> 3)
    r.read_bits(64).should eq IO::ByteFormat::LittleEndian.decode(UInt64, bytes[8, 8])
    r.read_bits(64).should eq IO::ByteFormat::LittleEndian.decode(UInt64, bytes[16, 8])
    r.eof?.should be_true
  end
end

describe Binary::BitWriter do
  it "writes MSB-first fields byte-exactly" do
    w = Binary::BitWriter.new
    w.write_bits(5, 3)
    w.write_bits(3, 5)
    w.write_bits(15, 4)
    w.write_bits(0, 4)
    w.to_slice.should eq Bytes[0b1010_0011, 0b1111_0000]
  end

  it "writes LSB-first fields byte-exactly" do
    w = Binary::BitWriter.new(:lsb)
    w.write_bits(3, 3)
    w.write_bits(20, 5)
    w.write_bits(0, 4)
    w.write_bits(15, 4)
    w.to_slice.should eq Bytes[0b1010_0011, 0b1111_0000]
  end

  it "pads the final partial byte with zero bits on flush" do
    w = Binary::BitWriter.new
    w.write_bits(0b101, 3)
    w.to_slice.should eq Bytes[0b1010_0000]
    w2 = Binary::BitWriter.new(:lsb)
    w2.write_bits(0b101, 3)
    w2.to_slice.should eq Bytes[0b0000_0101]
  end

  it "aligns by padding zero bits" do
    w = Binary::BitWriter.new
    w.write_bit(true)
    w.align!
    w.bit_position.should eq 8
    w.write_bits(0xAB, 8)
    w.to_slice.should eq Bytes[0x80, 0xAB]
  end

  it "writes 64-bit values across an unaligned boundary" do
    w = Binary::BitWriter.new
    w.write_bits(0xF, 4)
    w.write_bits(0x00123456789ABCDE_u64, 64)
    w.write_bits(0xF, 4)
    w.to_slice.should eq Bytes[0xF0, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
  end

  it "rejects values that do not fit and widths outside 0..64" do
    w = Binary::BitWriter.new
    expect_raises(ArgumentError) { w.write_bits(8, 3) }
    expect_raises(ArgumentError) { w.write_bits(0, 65) }
  end

  it "round-trips random widths through BitReader in both orders" do
    {Binary::BitOrder::Msb, Binary::BitOrder::Lsb}.each do |order|
      rng = Random.new(42)
      widths = Array.new(500) { rng.rand(1..64) }
      values = widths.map { |n| n == 64 ? rng.rand(UInt64) : rng.rand(1_u64 << n) }
      w = Binary::BitWriter.new(order)
      widths.zip(values) { |n, v| w.write_bits(v, n) }
      r = Binary::BitReader.new(w.to_slice, order)
      widths.zip(values) { |n, v| r.read_bits(n).should eq v }
    end
  end

  it "writes through to an IO on flush and close" do
    io = IO::Memory.new
    w = Binary::BitWriter.new(io)
    w.write_bits(0xABCD, 16)
    w.write_bits(1, 1)
    io.to_slice.should eq Bytes[0xAB, 0xCD]
    w.close
    io.to_slice.should eq Bytes[0xAB, 0xCD, 0x80]
  end
end
