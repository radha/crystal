# `Binary::Format` + bit IO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `require "binary"` additions: `Binary::BitReader`/`BitWriter`, and the `Binary::Format` macro module that turns a `field` DSL into `read`/`write`/`from_slice`/`to_slice`/`byte_size` with a zero-copy path for fixed layouts.

**Architecture:** Each DSL line (`field`, `pad`, `align`, `magic`, `endian`, `bit_order`) defines an annotated private marker def. A `macro finished` hook (stage 1) collects enum types and emits a stage-2 macro that evaluates `sizeof(EnumType)` with literal paths, then calls `__binary_generate(widths)`, which normalizes every entry into a macro-time hash and emits straight-line code. Runtime helpers live in `Binary::Format::Codec` (monomorphized generic methods, no reflection).

**Tech Stack:** Crystal (this repo's in-tree compiler via `bin/crystal`), stdlib `spec`, `IO::ByteFormat`, `IO::Sized`, `Binary::Varint`, `Binary::Frame`.

**Spec:** `docs/superpowers/specs/2026-09-17-binary-format-design.md`

## Global Constraints

- Run the compiler only through `bin/crystal` (never a global `crystal`). Filter linker noise: append `2>&1 | grep -v "ld64.lld\|Using compiled"` to run commands.
- One build at a time (8 GB machine). Never run two `bin/crystal` processes concurrently.
- `require "binary"` is the only entry point. Nothing goes in the prelude.
- Default endian is `:big`. Default `bit_order` is `:msb`. `max:` defaults: `Binary::Frame::DEFAULT_MAX_SIZE` (16 MiB) bytes, `16 * 1024 * 1024` elements. Count presize cap `65_536`.
- Errors: `Binary::Format::Error < Binary::Error`, `MagicError < Format::Error`, `SizeError < Format::Error`. Truncation raises `IO::EOFError`.
- Every public method gets a third-person doc comment. Run `make format` (or `bin/crystal tool format src/binary spec/std/binary`) before every commit.
- Spec files: `spec/std/binary/bit_io_spec.cr`, `spec/std/binary/format_spec.cr`. Run one file with `bin/crystal spec spec/std/binary/format_spec.cr`.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Verified macro facts (from spikes, do not re-spike): `@type.methods` inside `macro finished` lists defs in declaration order; `@type.methods.size` is a valid unique suffix inside a body macro; `Generic#resolve`/`Union#resolve` work on annotation-stored type ASTs at `finished` time; `TypeNode#instance_vars` does NOT work at `finished` time; macro `sizeof(X)` needs a literal path (hence stage 2); `finished` hooks run in definition order, so a nested format's constants are visible only if it is defined earlier in the file; `{{ opts.double_splat }}` leaves a harmless trailing comma; `uninitialized UInt8[SIZE]` needs `SIZE` to be a number-literal constant.

## File map

| file | responsibility |
|---|---|
| `src/binary/bit_order.cr` | `Binary::BitOrder` enum |
| `src/binary/bit_io.cr` | `Binary::BitReader`, `Binary::BitWriter` |
| `src/binary/format.cr` | `Binary::Format`: errors, `Codec` runtime helpers, DSL macros, stage-1/stage-2 hooks, `__binary_generate`, `__binary_read_scalar` / `__binary_write_scalar` / `__binary_size_scalar` helper macros |
| `src/binary.cr` | adds the three requires |
| `spec/std/binary/bit_io_spec.cr` | bit IO specs |
| `spec/std/binary/format_spec.cr` | format specs (fixtures at top, one `describe` per feature) |
| `.remember/harness-2026-09-17/format/` | gitignored benches and the compile-error script |

---

### Task 1: `BitOrder`, `BitReader`, `BitWriter`

**Files:**
- Create: `src/binary/bit_order.cr`
- Create: `src/binary/bit_io.cr`
- Modify: `src/binary.cr` (add requires)
- Test: `spec/std/binary/bit_io_spec.cr`

**Interfaces:**
- Produces: `enum Binary::BitOrder { Msb; Lsb }`; `Binary::BitReader.new(Bytes | IO, order : BitOrder = :msb)` with `read_bits(n) : UInt64`, `read_bits?(n) : UInt64?`, `read_bit : Bool`, `align! : Nil`, `bit_position : Int64`, `eof? : Bool`; `Binary::BitWriter.new(IO, order = :msb)` / `.new(order = :msb)` with `write_bits(UInt64, n)`, `write_bit(Bool)`, `align!`, `flush`, `close`, `bit_position`, `to_slice`.

- [ ] **Step 1: Write the failing specs**

```crystal
# spec/std/binary/bit_io_spec.cr
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
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bin/crystal spec spec/std/binary/bit_io_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: compile error `undefined constant Binary::BitReader`.

- [ ] **Step 3: Write `bit_order.cr` and `bit_io.cr`, add requires**

```crystal
# src/binary/bit_order.cr
module Binary
  # Order in which bits are packed into bytes by `BitReader`, `BitWriter`
  # and `bits:` fields of a `Binary::Format`.
  #
  # * `Msb`: the first bit written occupies the most significant bit of the
  #   first byte. Network protocol headers and most codecs use this order.
  # * `Lsb`: the first bit written occupies the least significant bit of the
  #   first byte. DEFLATE uses this order.
  enum BitOrder
    Msb
    Lsb
  end
end
```

```crystal
# src/binary/bit_io.cr
require "./bit_order"

module Binary
  # Reads bit fields from a `Bytes` or an `IO`.
  #
  # ```
  # reader = Binary::BitReader.new(Bytes[0b1010_0011])
  # reader.read_bits(3) # => 5
  # reader.read_bits(5) # => 3
  # ```
  #
  # A 64-bit accumulator holds pending bits. The slice-backed reader refills
  # eight bytes at a time whenever the accumulator is empty and at least eight
  # bytes remain; otherwise it refills one byte at a time.
  class BitReader
    @acc : UInt64 = 0
    @bits : Int32 = 0
    @bytes : Bytes?
    @io : IO?
    @pos : Int32 = 0
    @consumed : Int64 = 0

    # Creates a reader over *bytes* in the given bit *order*.
    def initialize(bytes : Bytes, @order : BitOrder = :msb)
      @bytes = bytes
    end

    # Creates a reader over *io* in the given bit *order*.
    def initialize(io : IO, @order : BitOrder = :msb)
      @io = io
    end

    # Returns the bit order of this reader.
    getter order : BitOrder

    # Reads *n* bits (`0..64`) and returns them as an unsigned integer.
    # Raises `IO::EOFError` if fewer than *n* bits remain and `ArgumentError`
    # if *n* is outside `0..64`.
    def read_bits(n : Int) : UInt64
      read_bits?(n) || raise IO::EOFError.new
    end

    # Like `read_bits` but returns `nil` if fewer than *n* bits remain.
    # No bits are consumed in that case.
    def read_bits?(n : Int) : UInt64?
      raise ArgumentError.new("bit width must be in 0..64, not #{n}") unless 0 <= n <= 64
      return 0_u64 if n == 0
      unless fill(n)
        return nil
      end
      take(n)
    end

    # Reads one bit.
    def read_bit : Bool
      read_bits(1) == 1
    end

    # Discards bits up to the next byte boundary.
    def align! : Nil
      rem = @bits & 7
      take(rem) if rem > 0
    end

    # Returns the number of bits consumed so far.
    def bit_position : Int64
      @consumed
    end

    # Returns `true` when no bits remain.
    def eof? : Bool
      return false if @bits > 0
      if bytes = @bytes
        @pos >= bytes.size
      else
        peek = @io.not_nil!.peek
        peek.nil? ? !fill(1) : peek.empty?
      end
    end

    # Ensures at least *n* bits are buffered. Returns `false` at end of data.
    # The accumulator never holds more than 64 bits: refills happen only while
    # `@bits < n <= 64`, adding 8 bits (or 64 when empty) each time.
    private def fill(n : Int32) : Bool
      while @bits < n
        if @bits == 0 && (bytes = @bytes) && bytes.size - @pos >= 8
          word = Slice.new(bytes.to_unsafe + @pos, 8)
          @acc = @order.msb? ? IO::ByteFormat::BigEndian.decode(UInt64, word) : IO::ByteFormat::LittleEndian.decode(UInt64, word)
          @pos += 8
          @bits = 64
          next
        end
        byte = next_byte
        return false unless byte
        if @order.msb?
          @acc = (@acc << 8) | byte
        else
          @acc |= byte.to_u64 << @bits
        end
        @bits += 8
      end
      true
    end

    private def next_byte : UInt8?
      if bytes = @bytes
        return nil if @pos >= bytes.size
        b = bytes.to_unsafe[@pos]
        @pos += 1
        b
      else
        @io.not_nil!.read_byte
      end
    end

    # Removes *n* (<= @bits) bits from the accumulator and returns them.
    private def take(n : Int32) : UInt64
      mask = n == 64 ? UInt64::MAX : (1_u64 << n) &- 1
      if @order.msb?
        @bits -= n
        value = (@acc >> @bits) & mask
        @acc &= (@bits == 64 ? UInt64::MAX : (1_u64 << @bits) &- 1)
      else
        value = @acc & mask
        @acc = n == 64 ? 0_u64 : @acc >> n
        @bits -= n
      end
      @consumed += n
      value
    end
  end

  # Writes bit fields to an `IO`, or to an internal buffer readable with
  # `to_slice`.
  #
  # ```
  # writer = Binary::BitWriter.new
  # writer.write_bits(5, 3)
  # writer.write_bits(3, 5)
  # writer.to_slice # => Bytes[0b1010_0011]
  # ```
  #
  # Whole bytes are written to the IO as soon as they complete. A trailing
  # partial byte is zero-padded and written by `flush`, `align!`, `close`
  # and `to_slice`.
  class BitWriter
    @acc : UInt64 = 0
    @bits : Int32 = 0
    @written : Int64 = 0

    # Returns the bit order of this writer.
    getter order : BitOrder

    # Creates a writer that emits bytes to *io*.
    def initialize(@io : IO, @order : BitOrder = :msb)
    end

    # Creates a writer over an internal buffer; read it back with `to_slice`.
    def initialize(@order : BitOrder = :msb)
      @io = IO::Memory.new
    end

    # Appends the low *n* bits (`0..64`) of *value*. Raises `ArgumentError`
    # if *value* does not fit in *n* bits or *n* is outside `0..64`.
    def write_bits(value : UInt64, n : Int) : Nil
      raise ArgumentError.new("bit width must be in 0..64, not #{n}") unless 0 <= n <= 64
      if n < 64 && value >= (1_u64 << n)
        raise ArgumentError.new("value #{value} does not fit in #{n} bits")
      end
      remaining = n.to_i32
      while remaining > 0
        chunk = Math.min(remaining, 64 - @bits)
        if @order.msb?
          part = (value >> (remaining - chunk)) & (chunk == 64 ? UInt64::MAX : (1_u64 << chunk) &- 1)
          @acc = (chunk == 64 ? 0_u64 : @acc << chunk) | part
        else
          part = value & (chunk == 64 ? UInt64::MAX : (1_u64 << chunk) &- 1)
          @acc |= part << @bits
          value = chunk == 64 ? 0_u64 : value >> chunk
        end
        @bits += chunk
        remaining -= chunk
        drain
      end
    end

    # :ditto:
    def write_bits(value : Int, n : Int) : Nil
      raise ArgumentError.new("negative values cannot be written as bits") if value < 0
      write_bits(value.to_u64, n)
    end

    # Appends one bit.
    def write_bit(bit : Bool) : Nil
      write_bits(bit ? 1_u64 : 0_u64, 1)
    end

    # Pads with zero bits up to the next byte boundary and writes that byte.
    def align! : Nil
      flush
    end

    # Writes the pending partial byte, zero-padded. No-op on a byte boundary.
    def flush : Nil
      return if @bits == 0
      byte = @order.msb? ? (@acc << (8 - @bits)) & 0xFF : @acc & 0xFF
      @io.write_byte(byte.to_u8!)
      @written += 8
      @acc = 0_u64
      @bits = 0
    end

    # Flushes and closes the underlying IO.
    def close : Nil
      flush
      @io.close
    end

    # Returns the number of bits written so far, including pending bits.
    def bit_position : Int64
      @written + @bits
    end

    # Flushes and returns everything written when constructed without an IO.
    def to_slice : Bytes
      flush
      io = @io
      raise ArgumentError.new("to_slice is only available for a BitWriter without an IO") unless io.is_a?(IO::Memory)
      io.to_slice
    end

    # Writes every complete byte out of the accumulator.
    private def drain : Nil
      while @bits >= 8
        if @order.msb?
          @bits -= 8
          @io.write_byte(((@acc >> @bits) & 0xFF).to_u8!)
          @acc &= (@bits == 0 ? 0_u64 : (1_u64 << @bits) &- 1)
        else
          @io.write_byte((@acc & 0xFF).to_u8!)
          @acc >>= 8
          @bits -= 8
        end
        @written += 8
      end
    end
  end
end
```

In `src/binary.cr` change the requires to:

```crystal
require "./binary/varint"
require "./binary/frame"
require "./binary/bit_order"
require "./binary/bit_io"
```

- [ ] **Step 4: Run the spec until it passes**

Run: `bin/crystal spec spec/std/binary/bit_io_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: all examples pass. If the "reads 64 bits after an unaligned prefix" example fails, check `take` for MSB: after `@bits -= n` the mask for the remaining accumulator must use the new `@bits`.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/binary spec/std/binary
git add src/binary/bit_order.cr src/binary/bit_io.cr src/binary.cr spec/std/binary/bit_io_spec.cr
git commit -m "Add Binary::BitReader and Binary::BitWriter

Bit-level IO over a Bytes or IO with MSB-first and LSB-first orders,
a 64-bit accumulator and 8-byte refills on slices.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `Binary::Format` core (scalars, endian, constructor, IO read/write)

**Files:**
- Create: `src/binary/format.cr`
- Modify: `src/binary.cr` (add `require "./binary/format"`)
- Test: `spec/std/binary/format_spec.cr`

**Interfaces:**
- Produces: `include Binary::Format`; `endian :big|:little|:native`; `field name : Type[, endian: ...]`; generated `initialize(*, kwargs)`, setters, `self.read(io)`, `self.from_slice(bytes)`, `self.from_slice(bytes, offset) : {self, Int32}`, `write(io)`, `to_slice`, `byte_size`, `self.fixed_size?` (false for now), constant `BINARY_FORMAT_FIXED`.
- Internal contract used by later tasks: each normalized entry hash `e` has keys `kind` (`:field`/`:pad`/`:magic`), `name`, `label`, `decl` (declared TypeNode, may be nilable), `type` (non-nil TypeNode), `nilable`, `cat` (`:int`/`:float`/`:bool`/`:enum`, later `:string`/`:bytes`/`:array`/`:static_array`/`:nested`), `width` (static byte width or nil), `endian`, `format` (MacroId of the `IO::ByteFormat` constant), `signed`, `has_default`, `default`, `derived` (Bool), `write_value` (MacroId expression or nil), `opts` (NamedTupleLiteral passed to helper macros). Helper macros: `__binary_read_scalar(io, cat, type, format, opts)`, `__binary_write_scalar(io, cat, type, format, value, opts)`, `__binary_size_scalar(cat, type, value, opts)`.

- [ ] **Step 1: Write the failing spec**

```crystal
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
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bin/crystal spec spec/std/binary/format_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: `undefined constant Binary::Format`.

- [ ] **Step 3: Write `src/binary/format.cr`**

```crystal
require "./varint"
require "./frame"
require "./bit_order"

module Binary
  # Declarative layout for binary structs. See the module docs added in Task 10.
  module Format
    # :nodoc:
    annotation Entry
    end

    # Raised for malformed input or values that cannot be encoded.
    class Error < Binary::Error
    end

    # Raised when a `magic` value read from the input does not match.
    class MagicError < Error
      getter expected : Bytes
      getter actual : Bytes

      def initialize(type : String, @expected : Bytes, @actual : Bytes)
        super("#{type}: magic mismatch, expected #{@expected.hexstring} but read #{@actual.hexstring}")
      end
    end

    # Raised when a length or count prefix exceeds its `max:` or is negative.
    class SizeError < Error
    end

    # Default `max:` for byte lengths.
    DEFAULT_MAX_BYTES = Binary::Frame::DEFAULT_MAX_SIZE
    # Default `max:` for element counts.
    DEFAULT_MAX_COUNT = 16 * 1024 * 1024
    # Largest capacity an array is presized to from a count prefix.
    PRESIZE_LIMIT = 65_536

    # :nodoc:
    #
    # Runtime helpers called by generated code.
    module Codec
      def self.read_bool(io : IO) : Bool
        (io.read_byte || raise IO::EOFError.new) != 0
      end

      def self.write_bool(io : IO, value : Bool) : Nil
        io.write_byte(value ? 1_u8 : 0_u8)
      end

      def self.read_enum(io : IO, type : T.class, format : IO::ByteFormat) : T forall T
        T.new(io.read_bytes(typeof(T.new(0).value), format))
      end

      def self.write_enum(io : IO, value : Enum, format : IO::ByteFormat) : Nil
        io.write_bytes(value.value, format)
      end

      # Placeholder value for derived fields in the keyword constructor.
      def self.zero(type : T.class) : T forall T
        {% if T < ::Enum %}
          T.new(typeof(T.new(0).value).zero)
        {% elsif T == ::Bool %}
          false
        {% else %}
          T.zero
        {% end %}
      end
    end

    # Sets the default byte order for every multi-byte field of this format.
    # One of `:big` (default), `:little` or `:native`.
    macro endian(value)
      {% raise "Binary::Format: endian must be :big, :little or :native, not #{value}" unless [:big, :little, :native].includes?(value) %}
      @[::Binary::Format::Entry(kind: :endian, value: {{value}})]
      private def __binary_directive_endian; end
    end

    # Declares the next field of the layout. See the module docs for options.
    macro field(decl, **opts)
      {% raise "Binary::Format: `field` expects `name : Type`, got `#{decl}`" unless decl.is_a?(TypeDeclaration) %}
      {% stored = decl.type.is_a?(Union) ? "::Union(#{decl.type.types.splat})".id : decl.type %}
      @{{decl.var}} : {{decl.type}}

      def {{decl.var}} : {{decl.type}}
        @{{decl.var}}
      end

      @[::Binary::Format::Entry(kind: :field, name: {{decl.var.symbolize}}, type: {{stored}}, has_default: {{!decl.value.is_a?(Nop)}}, default: {{decl.value.is_a?(Nop) ? nil : decl.value}}, {{opts.double_splat}})]
      private def __binary_entry_{{decl.var}}; end
    end

    macro included
      macro finished
        __binary_stage1
      end
    end

    # :nodoc:
    #
    # Stage 1 runs in `macro finished`. It cannot evaluate `sizeof` on a type
    # held in a macro variable, so it emits stage 2 with literal type paths.
    macro __binary_stage1
      {% enum_entries = [] of Nil %}
      {% for m in @type.methods %}
        {% a = m.annotation(::Binary::Format::Entry) %}
        {% if a && a[:kind] == :field %}
          {% t = a[:type].resolve %}
          {% if t.nilable? %}
            {% t = t.union_types.reject { |u| u == ::Nil }[0] %}
          {% end %}
          {% if t < ::Enum %}
            {% enum_entries << {a[:name].id, t} %}
          {% elsif (t.name.starts_with?("StaticArray(") || t.name.starts_with?("Array(")) && t.type_vars[0] < ::Enum %}
            {% enum_entries << {"#{a[:name].id}__elem".id, t.type_vars[0]} %}
          {% end %}
        {% end %}
      {% end %}
      macro __binary_stage2
        \{% widths = { __binary_none: 0, {% for pair in enum_entries %} {{pair[0]}}: sizeof({{pair[1]}}), {% end %} } %}
        __binary_generate(\{{ widths }})
      end
      __binary_stage2
    end

    # :nodoc:
    macro __binary_read_scalar(io, cat, type, format, opts)
      {% if cat == :int || cat == :float %}
        {{io}}.read_bytes({{type}}, {{format}})
      {% elsif cat == :bool %}
        ::Binary::Format::Codec.read_bool({{io}})
      {% elsif cat == :enum %}
        ::Binary::Format::Codec.read_enum({{io}}, {{type}}, {{format}})
      {% else %}
        {% raise "Binary::Format: cannot read #{cat}" %}
      {% end %}
    end

    # :nodoc:
    macro __binary_write_scalar(io, cat, type, format, value, opts)
      {% if cat == :int || cat == :float %}
        {{io}}.write_bytes({{value}}, {{format}})
      {% elsif cat == :bool %}
        ::Binary::Format::Codec.write_bool({{io}}, {{value}})
      {% elsif cat == :enum %}
        ::Binary::Format::Codec.write_enum({{io}}, {{value}}, {{format}})
      {% else %}
        {% raise "Binary::Format: cannot write #{cat}" %}
      {% end %}
    end

    # :nodoc:
    macro __binary_size_scalar(cat, type, value, opts)
      {% if cat == :int || cat == :float || cat == :bool || cat == :enum %}
        {{opts[:width]}}
      {% else %}
        {% raise "Binary::Format: cannot size #{cat}" %}
      {% end %}
    end

    # :nodoc:
    macro __binary_generate(widths)
      {% type_endian = :big %}
      {% raw = [] of Nil %}
      {% for m in @type.methods %}
        {% a = m.annotation(::Binary::Format::Entry) %}
        {% if a %}
          {% if a[:kind] == :endian %}
            {% type_endian = a[:value] %}
          {% else %}
            {% raw << a %}
          {% end %}
        {% end %}
      {% end %}

      {%
        type_name = @type.name.stringify
        int_widths = {"Int8" => 1, "UInt8" => 1, "Int16" => 2, "UInt16" => 2, "Int32" => 4, "UInt32" => 4, "Int64" => 8, "UInt64" => 8, "Int128" => 16, "UInt128" => 16}
        float_widths = {"Float32" => 4, "Float64" => 8}
        formats = {big: "::IO::ByteFormat::BigEndian".id, little: "::IO::ByteFormat::LittleEndian".id, native: "::IO::ByteFormat::SystemEndian".id}
        internal_keys = ["kind", "name", "type", "has_default", "default"]
        entries = [] of Nil
        offset = 0
        fixed = true
      %}

      {% for a in raw %}
        {% e = {} of Nil => Nil %}
        {% e[:kind] = a[:kind] %}
        {% e[:width] = nil %}
        {% e[:derived] = false %}
        {% e[:write_value] = nil %}
        {% if a[:kind] == :field %}
          {% e[:name] = a[:name].id %}
          {% e[:label] = "#{type_name}##{a[:name].id}" %}
          {% e[:has_default] = a[:has_default] %}
          {% e[:default] = a[:default] %}
          {% decl = a[:type].resolve %}
          {% e[:decl] = decl %}
          {% e[:nilable] = decl.nilable? %}
          {% if decl.nilable? %}
            {% inner = decl.union_types.reject { |u| u == ::Nil } %}
            {% raise "#{e[:label]}: only `T?` unions are supported" unless inner.size == 1 %}
            {% t = inner[0] %}
          {% else %}
            {% t = decl %}
          {% end %}
          {% e[:type] = t %}
          {% e[:endian] = a[:endian] || type_endian %}
          {% raise "#{e[:label]}: endian must be :big, :little or :native" unless [:big, :little, :native].includes?(e[:endian]) %}
          {% e[:format] = formats[e[:endian]] %}
          {% e[:signed] = false %}
          {% allowed = ["endian"] %}
          {% tname = t.name.stringify %}
          {% if t < ::Int && int_widths[tname] %}
            {% e[:cat] = :int %}
            {% e[:width] = int_widths[tname] %}
            {% e[:signed] = tname.starts_with?("Int") %}
          {% elsif float_widths[tname] %}
            {% e[:cat] = :float %}
            {% e[:width] = float_widths[tname] %}
          {% elsif t == ::Bool %}
            {% e[:cat] = :bool %}
            {% e[:width] = 1 %}
          {% elsif t < ::Enum %}
            {% e[:cat] = :enum %}
            {% e[:width] = widths[e[:name]] %}
          {% else %}
            {% raise "#{e[:label]}: unsupported field type #{t}" %}
          {% end %}
          {% for key in a.named_args.keys %}
            {% ks = key.id.stringify %}
            {% unless internal_keys.includes?(ks) || allowed.includes?(ks) %}
              {% raise "#{e[:label]}: option `#{ks}:` is not valid for a #{t} field (allowed: #{allowed.join(", ").id})" %}
            {% end %}
          {% end %}
          {% e[:opts] = {label: e[:label], width: e[:width], signed: e[:signed]} %}
        {% else %}
          {% raise "Binary::Format: unknown entry kind #{a[:kind]}" %}
        {% end %}
        {% if e[:width].nil? %}
          {% fixed = false %}
          {% offset = nil %}
        {% elsif offset %}
          {% e[:offset] = offset %}
          {% offset = offset + e[:width] %}
        {% end %}
        {% entries << e %}
      {% end %}

      {% fields = entries.select { |x| x[:kind] == :field } %}
      {% plain = fields.reject { |x| x[:derived] } %}

      # :nodoc:
      BINARY_FORMAT_FIXED = {{fixed}}

      # Returns `true` if every field has a compile-time width.
      def self.fixed_size? : Bool
        BINARY_FORMAT_FIXED
      end

      {% for e in plain %}
        def {{e[:name]}}=(value : {{e[:decl]}}) : {{e[:decl]}}
          @{{e[:name]}} = value
        end
      {% end %}

      {% params = plain.map { |x| "@#{x[:name]} : #{x[:decl]}#{x[:has_default] ? " = #{x[:default]}" : (x[:nilable] ? " = nil" : "")}" } %}
      {% if params.empty? %}
        def initialize
      {% else %}
        def initialize(*, {{params.join(", ").id}})
      {% end %}
        {% for e in fields.select { |x| x[:derived] } %}
          @{{e[:name]}} = ::Binary::Format::Codec.zero({{e[:type]}})
        {% end %}
      end

      # Reads one record from *io*. Raises `IO::EOFError` on truncated input.
      def self.read(io : IO) : self
        new(__binary_io: io)
      end

      # Parses one record from the start of *bytes*.
      def self.from_slice(bytes : Bytes) : self
        read(::IO::Memory.new(bytes, writeable: false))
      end

      # Parses one record starting at *offset* and returns it with the number
      # of bytes consumed.
      def self.from_slice(bytes : Bytes, offset : Int) : {self, Int32}
        io = ::IO::Memory.new(bytes + offset, writeable: false)
        {read(io), io.pos.to_i32}
      end

      # :nodoc:
      def initialize(*, __binary_io __io : IO)
        {% for e in entries %}
          {% if e[:kind] == :field %}
            {{e[:name]}} = __binary_read_scalar(__io, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, {{e[:opts]}})
          {% end %}
        {% end %}
        {% for e in fields %}
          @{{e[:name]}} = {{e[:name]}}
        {% end %}
      end

      # Writes this record to *io*.
      def write(__io : IO) : Nil
        {% for e in entries %}
          {% if e[:kind] == :field %}
            __binary_write_scalar(__io, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, {{e[:write_value] || "@#{e[:name]}".id}}, {{e[:opts]}})
          {% end %}
        {% end %}
      end

      # Returns the encoded size in bytes without writing anything.
      def byte_size : Int32
        0 {% for e in entries %} {% if e[:kind] == :field %} &+ (__binary_size_scalar({{e[:cat]}}, {{e[:type]}}, {{e[:write_value] || "@#{e[:name]}".id}}, {{e[:opts]}})) {% end %} {% end %}
      end

      # Returns this record encoded into a new `Bytes` of exactly `byte_size`.
      def to_slice : Bytes
        bytes = Bytes.new(byte_size)
        write(::IO::Memory.new(bytes))
        bytes
      end
    end
  end
end
```

Add `require "./binary/format"` as the last line of `src/binary.cr`.

- [ ] **Step 4: Run the spec until it passes**

Run: `bin/crystal spec spec/std/binary/format_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: 5 examples pass. Likely first-run problems and their fixes:
- `unterminated annotation` or stray comma: the annotation line in `field`; if the trailing comma from `opts.double_splat` is rejected, emit `{% unless opts.empty? %}, {{opts.double_splat}}{% end %}` and drop the comma before it.
- `undefined macro method 'NamedTupleLiteral#keys'`: replace the loop with `{% for key, _v in a.named_args %}`.
- `formats[e[:endian]]` returning nil: the annotation value is a `SymbolLiteral`; index with `formats[e[:endian].id.symbolize]`.
- `def initialize(*, ...)` parse error on the joined params: print `{{params}}` with `{% debug %}` and check the string; defaults containing commas (e.g. `Bytes[1, 2]`) are fine because they are inside brackets.
- struct equality in `should eq`: structs compare by ivars, so `Header.from_slice(bytes).should eq back` works without extra code.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/binary spec/std/binary
git add src/binary/format.cr src/binary.cr spec/std/binary/format_spec.cr
git commit -m "Add Binary::Format core: field DSL, endian, scalar read/write

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `pad`, `align`, `magic`

**Files:**
- Modify: `src/binary/format.cr` (DSL macros, `Codec`, `__binary_generate` normalization and codegen)
- Test: `spec/std/binary/format_spec.cr`

**Interfaces:**
- Consumes: entry hash contract and `__binary_generate` from Task 2.
- Produces: `pad n`, `align n`, `magic value`; entry kinds `:pad` (with `width`) and `:magic` (with `width`, `index`, `const_expr`); constants `BINARY_MAGIC_<index>`; `Codec.write_zeros`, `Codec.read_magic`, `Codec.check_magic`.

- [ ] **Step 1: Add the failing specs**

Add these fixtures after `Mixed` and this `describe` inside `describe Binary::Format`:

```crystal
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
```

```crystal
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
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bin/crystal spec spec/std/binary/format_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: `undefined macro 'magic'` (or `pad`).

- [ ] **Step 3: Add the DSL macros**

Insert after `macro endian`:

```crystal
    # Skips *size* bytes on read and writes *size* zero bytes.
    macro pad(size)
      {% raise "Binary::Format: `pad` expects a positive integer literal, got `#{size}`" unless size.is_a?(NumberLiteral) && size > 0 %}
      @[::Binary::Format::Entry(kind: :pad, size: {{size}})]
      private def __binary_entry_pad_{{@type.methods.size}}; end
    end

    # Pads to the next multiple of *size* bytes counted from the start of the
    # record. Every entry before it must have a fixed width.
    macro align(size)
      {% raise "Binary::Format: `align` expects a positive integer literal, got `#{size}`" unless size.is_a?(NumberLiteral) && size > 0 %}
      @[::Binary::Format::Entry(kind: :align, size: {{size}})]
      private def __binary_entry_align_{{@type.methods.size}}; end
    end

    # Declares constant bytes: a `String` (ASCII only), `Bytes[...]`, or an
    # integer literal with a type suffix (written in the type's endian).
    # Read asserts the bytes and raises `MagicError` on mismatch.
    macro magic(value)
      {% if value.is_a?(StringLiteral) %}
        {% raise "Binary::Format: a String magic must be ASCII, use Bytes[...] otherwise" unless value =~ /\A[\x00-\x7f]*\z/ %}
      {% elsif value.is_a?(NumberLiteral) %}
        {% raise "Binary::Format: an integer magic needs a type suffix, e.g. 0x89504E47_u32" unless value.kind.id.stringify =~ /\A[ui](8|16|32|64|128)\z/ %}
      {% elsif !(value.is_a?(Call) && value.name == "[]") %}
        {% raise "Binary::Format: magic must be a String, Bytes[...] or a suffixed integer literal, got `#{value}`" %}
      {% end %}
      @[::Binary::Format::Entry(kind: :magic, value: {{value}})]
      private def __binary_entry_magic_{{@type.methods.size}}; end
    end
```

- [ ] **Step 4: Add the `Codec` helpers**

Insert inside `module Codec` after `write_enum`:

```crystal
      ZEROS = Bytes.new(64)

      def self.write_zeros(io : IO, count : Int32) : Nil
        while count > 0
          n = Math.min(count, ZEROS.size)
          io.write(ZEROS[0, n])
          count -= n
        end
      end

      def self.check_magic(actual : Bytes, expected : Bytes, type : String) : Nil
        raise MagicError.new(type, expected, actual) unless actual == expected
      end

      def self.read_magic(io : IO, expected : Bytes, type : String) : Nil
        actual = Bytes.new(expected.size)
        io.read_fully(actual)
        check_magic(actual, expected, type)
      end
```

- [ ] **Step 5: Normalize the new entry kinds**

In `__binary_generate`, add to the `{% ... %}` block that defines `int_widths` the line:

```crystal
        magic_widths = {"i8" => 1, "u8" => 1, "i16" => 2, "u16" => 2, "i32" => 4, "u32" => 4, "i64" => 8, "u64" => 8, "i128" => 16, "u128" => 16}
```

Replace the branch `{% else %} {% raise "Binary::Format: unknown entry kind #{a[:kind]}" %}` with:

```crystal
        {% elsif a[:kind] == :pad %}
          {% e[:width] = a[:size] %}
        {% elsif a[:kind] == :align %}
          {% raise "#{type_name}: `align #{a[:size]}` needs every preceding entry to have a fixed width" unless offset %}
          {% e[:kind] = :pad %}
          {% e[:width] = (a[:size] - offset % a[:size]) % a[:size] %}
        {% elsif a[:kind] == :magic %}
          {% v = a[:value] %}
          {% e[:index] = entries.size %}
          {% if v.is_a?(StringLiteral) %}
            {% e[:width] = v.size %}
            {% e[:const_expr] = "#{v}.to_slice".id %}
          {% elsif v.is_a?(NumberLiteral) %}
            {% e[:width] = magic_widths[v.kind.id.stringify] %}
            {% e[:const_expr] = "(::IO::Memory.new(#{e[:width]}).tap { |m| m.write_bytes(#{v}, #{formats[type_endian]}) }.to_slice)".id %}
          {% else %}
            {% e[:width] = v.args.size %}
            {% e[:const_expr] = v %}
          {% end %}
        {% else %}
          {% raise "Binary::Format: unknown entry kind #{a[:kind]}" %}
```

- [ ] **Step 6: Emit constants and read/write/size code**

Right after `BINARY_FORMAT_FIXED = {{fixed}}` add:

```crystal
      {% for e in entries %}
        {% if e[:kind] == :magic %}
          # :nodoc:
          BINARY_MAGIC_{{e[:index]}} = {{e[:const_expr]}}
        {% end %}
      {% end %}
```

In `initialize(*, __binary_io __io : IO)` replace the `{% if e[:kind] == :field %} ... {% end %}` body with:

```crystal
          {% if e[:kind] == :pad %}
            {% if e[:width] > 0 %} __io.skip({{e[:width]}}) {% end %}
          {% elsif e[:kind] == :magic %}
            ::Binary::Format::Codec.read_magic(__io, BINARY_MAGIC_{{e[:index]}}, {{type_name}})
          {% elsif e[:kind] == :field %}
            {{e[:name]}} = __binary_read_scalar(__io, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, {{e[:opts]}})
          {% end %}
```

In `write(__io : IO)` replace the body of the loop with:

```crystal
          {% if e[:kind] == :pad %}
            {% if e[:width] > 0 %} ::Binary::Format::Codec.write_zeros(__io, {{e[:width]}}) {% end %}
          {% elsif e[:kind] == :magic %}
            __io.write(BINARY_MAGIC_{{e[:index]}})
          {% elsif e[:kind] == :field %}
            __binary_write_scalar(__io, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, {{e[:write_value] || "@#{e[:name]}".id}}, {{e[:opts]}})
          {% end %}
```

In `byte_size` replace the loop with:

```crystal
        0 {% for e in entries %} {% if e[:kind] == :field %} &+ (__binary_size_scalar({{e[:cat]}}, {{e[:type]}}, {{e[:write_value] || "@#{e[:name]}".id}}, {{e[:opts]}})) {% else %} &+ {{e[:width]}} {% end %} {% end %}
```

- [ ] **Step 7: Run the spec until it passes**

Run: `bin/crystal spec spec/std/binary/format_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: 10 examples pass. If `v.kind` is not a macro method on `NumberLiteral`, use `v.kind` via `{{ }}` debug; it is documented as `NumberLiteral#kind : SymbolLiteral`. If `value =~` fails on `StringLiteral`, replace with `value.chars.all? { |c| c.ord < 128 }` (StringLiteral#chars exists).

- [ ] **Step 8: Format and commit**

```bash
bin/crystal tool format src/binary spec/std/binary
git add src/binary/format.cr spec/std/binary/format_spec.cr
git commit -m "Binary::Format: pad, align and magic entries

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `String` and `Bytes` fields, derived length fields

**Files:**
- Modify: `src/binary/format.cr`
- Test: `spec/std/binary/format_spec.cr`

**Interfaces:**
- Consumes: entry contract, `e[:opts]`.
- Produces: categories `:string`, `:bytes`; option keys `length:` (Symbol / Int / proc), `cstring:`, `until: :eof`, `max:`; `e[:mode]` in `:cstring | :rest | :fixed | :ref | :length`; `e[:length]` expression; `e[:length_ref]`; `e[:pos]`; derived marking (`e[:derived]`, `e[:write_value]`), derived ivars computed in the constructor; `Codec.check_size`, `read_string`, `read_cstring`, `read_rest_string`, `read_bytes`, `read_rest_bytes`, `write_cstring`, `write_exact`.

- [ ] **Step 1: Add the failing specs**

Fixture:

```crystal
private struct Texts
  include Binary::Format
  field name_len : UInt8
  field name : String, length: :name_len
  field tag : String, length: 4
  field note : String, cstring: true
  field n : UInt8
  field twice : Bytes, length: ->{ n * 2 }
  field rest : Bytes, until: :eof
end

private struct Capped
  include Binary::Format
  field len : UInt32
  field body : Bytes, length: :len, max: 8
end
```

Specs:

```crystal
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
```

Add this helper class at the top of the spec file, after the requires:

```crystal
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
```

- [ ] **Step 2: Run the spec to verify it fails**

Expected: `Texts#name: unsupported field type String` (a macro raise).

- [ ] **Step 3: Add `Codec` helpers**

Insert into `module Codec`:

```crystal
      def self.check_size(size : Int, max : Int32, label : String) : Int32
        if size < 0 || size > max
          raise SizeError.new("#{label}: size #{size} is outside 0..#{max}")
        end
        size.to_i32
      end

      def self.read_string(io : IO, size : Int, max : Int32, label : String) : String
        io.read_string(check_size(size, max, label))
      end

      def self.read_cstring(io : IO, label : String) : String
        str = io.gets('\0', chomp: false) || raise IO::EOFError.new
        raise IO::EOFError.new unless str.ends_with?('\0')
        str.byte_slice(0, str.bytesize - 1)
      end

      def self.read_bytes(io : IO, size : Int, max : Int32, label : String) : Bytes
        buf = Bytes.new(check_size(size, max, label))
        io.read_fully(buf)
        buf
      end

      def self.read_rest_bytes(io : IO, max : Int32, label : String) : Bytes
        if io.is_a?(IO::Sized)
          read_bytes(io, io.read_remaining, max, label)
        else
          mem = IO::Memory.new
          IO.copy(io, mem, max.to_i64 + 1)
          check_size(mem.size, max, label)
          mem.to_slice
        end
      end

      def self.read_rest_string(io : IO, max : Int32, label : String) : String
        String.new(read_rest_bytes(io, max, label))
      end

      def self.write_cstring(io : IO, value : String, label : String) : Nil
        raise Error.new("#{label}: string contains a NUL byte") if value.byte_index(0_u8)
        io.write(value.to_slice)
        io.write_byte(0_u8)
      end

      def self.write_exact(io : IO, value : Bytes, size : Int, label : String) : Nil
        raise Error.new("#{label}: expected #{size} bytes but the value has #{value.size}") unless value.size == size
        io.write(value)
      end
```

- [ ] **Step 4: Normalize String/Bytes fields and resolve derived references**

In the classification chain of `__binary_generate`, before the final `{% else %}` that raises "unsupported field type", add:

```crystal
          {% elsif t == ::String %}
            {% e[:cat] = :string %}
            {% allowed = ["length", "cstring", "until", "max"] %}
          {% elsif tname == "Slice(UInt8)" %}
            {% e[:cat] = :bytes %}
            {% allowed = ["length", "until", "max"] %}
```

After the classification chain (before the `{% for key in a.named_args.keys %}` validation) add:

```crystal
          {% e[:mode] = nil %}
          {% e[:length] = nil %}
          {% e[:max] = nil %}
          {% if e[:cat] == :string || e[:cat] == :bytes %}
            {% modes = 0 %}
            {% modes = modes + 1 if a[:length] %}
            {% modes = modes + 1 if a[:cstring] %}
            {% modes = modes + 1 if a[:until] %}
            {% raise "#{e[:label]}: needs exactly one of `length:`, `cstring: true` or `until: :eof`" unless modes == 1 %}
            {% raise "#{e[:label]}: `until:` must be :eof" if a[:until] && a[:until] != :eof %}
            {% e[:max] = a[:max] || "::Binary::Format::DEFAULT_MAX_BYTES".id %}
            {% if a[:cstring] %}
              {% e[:mode] = :cstring %}
            {% elsif a[:until] %}
              {% e[:mode] = :rest %}
            {% elsif a[:length].is_a?(SymbolLiteral) %}
              {% e[:mode] = :ref %}
              {% e[:length_ref] = a[:length].id %}
              {% e[:length] = a[:length].id %}
            {% elsif a[:length].is_a?(NumberLiteral) %}
              {% e[:mode] = :fixed %}
              {% e[:length] = a[:length] %}
              {% e[:width] = a[:length] %}
            {% elsif a[:length].is_a?(ProcLiteral) %}
              {% e[:mode] = :length %}
              {% e[:length] = "(#{a[:length].body})".id %}
            {% else %}
              {% raise "#{e[:label]}: `length:` must be a field name symbol, an integer literal or a `->{ }` block" %}
            {% end %}
          {% end %}
```

Change the `e[:opts]` line to:

```crystal
          {% e[:opts] = {label: e[:label], width: e[:width], signed: e[:signed], mode: e[:mode], length: e[:length], max: e[:max]} %}
```

Just before `{% entries << e %}` add `{% e[:pos] = entries.size %}`.

After the `{% for a in raw %} ... {% end %}` loop and before `{% fields = ... %}` add the derived resolution pass:

```crystal
      {% for e in entries %}
        {% if e[:length_ref] %}
          {% target = nil %}
          {% for x in entries %}
            {% target = x if x[:kind] == :field && x[:name] == e[:length_ref] %}
          {% end %}
          {% raise "#{e[:label]}: `length: :#{e[:length_ref]}` names an unknown field" unless target %}
          {% raise "#{e[:label]}: `length: :#{e[:length_ref]}` must name an integer field declared before it" unless target[:cat] == :int && target[:pos] < e[:pos] %}
          {% raise "#{target[:label]}: a derived field cannot have a default value" if target[:has_default] %}
          {% target[:derived] = true %}
          {% measure = e[:cat] == :string ? "bytesize" : "size" %}
          {% if e[:nilable] %}
            {% target[:write_value] = "#{target[:type]}.new(#{e[:name]}.try(&.#{measure.id}) || 0)".id %}
          {% else %}
            {% target[:write_value] = "#{target[:type]}.new(#{e[:name]}.#{measure.id})".id %}
          {% end %}
        {% end %}
      {% end %}
```

In the keyword constructor, after the zero-initialization loop, add:

```crystal
        {% for e in fields.select { |x| x[:derived] } %}
          @{{e[:name]}} = {{e[:write_value]}}
        {% end %}
```

- [ ] **Step 5: Add read/write/size branches**

In `__binary_read_scalar`, before the final `{% else %}`:

```crystal
      {% elsif cat == :string %}
        {% if opts[:mode] == :cstring %}
          ::Binary::Format::Codec.read_cstring({{io}}, {{opts[:label]}})
        {% elsif opts[:mode] == :rest %}
          ::Binary::Format::Codec.read_rest_string({{io}}, {{opts[:max]}}, {{opts[:label]}})
        {% else %}
          ::Binary::Format::Codec.read_string({{io}}, {{opts[:length]}}, {{opts[:max]}}, {{opts[:label]}})
        {% end %}
      {% elsif cat == :bytes %}
        {% if opts[:mode] == :rest %}
          ::Binary::Format::Codec.read_rest_bytes({{io}}, {{opts[:max]}}, {{opts[:label]}})
        {% else %}
          ::Binary::Format::Codec.read_bytes({{io}}, {{opts[:length]}}, {{opts[:max]}}, {{opts[:label]}})
        {% end %}
```

In `__binary_write_scalar`:

```crystal
      {% elsif cat == :string || cat == :bytes %}
        {% if opts[:mode] == :cstring %}
          ::Binary::Format::Codec.write_cstring({{io}}, {{value}}, {{opts[:label]}})
        {% elsif opts[:mode] == :fixed || opts[:mode] == :length %}
          ::Binary::Format::Codec.write_exact({{io}}, {{value}}.to_slice, {{opts[:length]}}, {{opts[:label]}})
        {% else %}
          {{io}}.write({{value}}.to_slice)
        {% end %}
```

In `__binary_size_scalar`:

```crystal
      {% elsif cat == :string %}
        {% if opts[:mode] == :cstring %}
          ({{value}}.bytesize &+ 1)
        {% else %}
          {{value}}.bytesize
        {% end %}
      {% elsif cat == :bytes %}
        {{value}}.size
```

- [ ] **Step 6: Run the spec until it passes**

Run: `bin/crystal spec spec/std/binary/format_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: 15 examples pass. Notes: `Bytes#to_slice` exists (returns self), so the `write_exact` branch works for both categories. If `x[:name] == e[:length_ref]` never matches, both sides must be `MacroId`; compare `x[:name].stringify == e[:length_ref].stringify` instead.

- [ ] **Step 7: Format and commit**

```bash
bin/crystal tool format src/binary spec/std/binary
git add src/binary/format.cr spec/std/binary/format_spec.cr
git commit -m "Binary::Format: String and Bytes fields with derived lengths

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `Array`, `StaticArray` and nested formats

**Files:**
- Modify: `src/binary/format.cr`
- Test: `spec/std/binary/format_spec.cr`

**Interfaces:**
- Consumes: Task 4 modes and derived resolution.
- Produces: categories `:array`, `:static_array`, `:nested`; element keys `e[:elem]`, `e[:ecat]`, `e[:ewidth]`, `e[:eopts]`; array keys `e[:amode]` in `:ref | :fixed | :proc | :rest | :sentinel`, `e[:count]`, `e[:count_ref]`, `e[:sentinel]`; `Codec.check_count`, `Codec.check_exact_count`, `Codec.rest?`.

- [ ] **Step 1: Add the failing specs**

Fixtures:

```crystal
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
  field more : Array(UInt16), count: ->{ n + 1 }
end
```

Specs:

```crystal
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
  end
```

- [ ] **Step 2: Run the spec to verify it fails**

Expected: `Shapes#points: unsupported field type Array(Point)`.

- [ ] **Step 3: Add `Codec` helpers**

```crystal
      def self.check_count(count : Int, max : Int32, label : String) : Int32
        if count < 0 || count > max
          raise SizeError.new("#{label}: count #{count} is outside 0..#{max}")
        end
        count.to_i32
      end

      def self.check_exact_count(actual : Int, expected : Int, label : String) : Nil
        raise Error.new("#{label}: expected #{expected} elements but the value has #{actual}") unless actual == expected
      end

      def self.rest?(io : IO, label : String) : Bool
        peek = io.peek
        if peek.nil?
          raise Error.new("#{label}: `until: :eof` needs an IO that supports peek, #{io.class} does not")
        end
        !peek.empty?
      end
```

- [ ] **Step 4: Replace the classification chain with a two-level one**

Replace everything from `{% e[:signed] = false %}` through the end of the classification `{% end %}` (the chain ending in `unsupported field type`) with:

```crystal
          {% e[:signed] = false %}
          {% allowed = ["endian"] %}
          {% tname = t.name.stringify %}
          {% elem = nil %}
          {% if tname.starts_with?("StaticArray(") || tname.starts_with?("Array(") %}
            {% elem = t.type_vars[0] %}
          {% end %}
          {% cats = [] of Nil %}
          {% ws = [] of Nil %}
          {% sg = [] of Nil %}
          {% for tt in (elem ? [t, elem] : [t]) %}
            {% tn = tt.name.stringify %}
            {% if tt < ::Int && int_widths[tn] %}
              {% cats << :int %}
              {% ws << int_widths[tn] %}
              {% sg << tn.starts_with?("Int") %}
            {% elsif float_widths[tn] %}
              {% cats << :float %}
              {% ws << float_widths[tn] %}
              {% sg << false %}
            {% elsif tt == ::Bool %}
              {% cats << :bool %}
              {% ws << 1 %}
              {% sg << false %}
            {% elsif tt < ::Enum %}
              {% cats << :enum %}
              {% ws << (cats.size == 1 ? widths[e[:name]] : widths["#{e[:name]}__elem".id]) %}
              {% sg << false %}
            {% elsif tt == ::String %}
              {% cats << :string %}
              {% ws << nil %}
              {% sg << false %}
            {% elsif tn == "Slice(UInt8)" %}
              {% cats << :bytes %}
              {% ws << nil %}
              {% sg << false %}
            {% elsif tn.starts_with?("StaticArray(") %}
              {% raise "#{e[:label]}: arrays of arrays are not supported" unless cats.empty? %}
              {% cats << :static_array %}
              {% ws << nil %}
              {% sg << false %}
            {% elsif tn.starts_with?("Array(") %}
              {% raise "#{e[:label]}: arrays of arrays are not supported" unless cats.empty? %}
              {% cats << :array %}
              {% ws << nil %}
              {% sg << false %}
            {% elsif tt <= ::Binary::Format %}
              {% raise "#{e[:label]}: #{tt} must be defined before #{@type} because it is embedded in it" unless tt.has_constant?(:BINARY_FORMAT_FIXED) %}
              {% cats << :nested %}
              {% ws << (tt.constant(:BINARY_FORMAT_FIXED) ? tt.constant(:SIZE) : nil) %}
              {% sg << false %}
            {% else %}
              {% raise "#{e[:label]}: unsupported field type #{tt}" %}
            {% end %}
          {% end %}
          {% e[:cat] = cats[0] %}
          {% e[:width] = ws[0] %}
          {% e[:signed] = sg[0] %}
          {% if e[:cat] == :string %}
            {% allowed = ["length", "cstring", "until", "max"] %}
          {% elsif e[:cat] == :bytes %}
            {% allowed = ["length", "until", "max"] %}
          {% elsif e[:cat] == :nested %}
            {% allowed = [] of Nil %}
          {% elsif e[:cat] == :static_array %}
            {% allowed = ["endian", "cstring", "length"] %}
          {% elsif e[:cat] == :array %}
            {% allowed = ["endian", "cstring", "length", "count", "until", "sentinel", "max"] %}
          {% end %}
```

Note: `SIZE` for fixed nested formats is generated in Task 8; until then `tt.constant(:BINARY_FORMAT_FIXED)` is always `false` for a nested type, so `ws << nil`, which is correct.

- [ ] **Step 5: Normalize element options and array modes**

After the String/Bytes options block from Task 4 (the `{% if e[:cat] == :string || e[:cat] == :bytes %} ... {% end %}`), add:

```crystal
          {% e[:eopts] = nil %}
          {% e[:amode] = nil %}
          {% e[:count] = nil %}
          {% e[:sentinel] = nil %}
          {% if elem %}
            {% e[:elem] = elem %}
            {% e[:ecat] = cats[1] %}
            {% e[:ewidth] = ws[1] %}
            {% emode = nil %}
            {% elength = nil %}
            {% if e[:ecat] == :string %}
              {% if a[:cstring] %}
                {% emode = :cstring %}
              {% elsif a[:length].is_a?(NumberLiteral) %}
                {% emode = :fixed %}
                {% elength = a[:length] %}
                {% e[:ewidth] = a[:length] %}
              {% else %}
                {% raise "#{e[:label]}: String elements need `cstring: true` or `length: <integer>`" %}
              {% end %}
            {% elsif e[:ecat] == :bytes %}
              {% raise "#{e[:label]}: Bytes elements need `length: <integer>`" unless a[:length].is_a?(NumberLiteral) %}
              {% emode = :fixed %}
              {% elength = a[:length] %}
              {% e[:ewidth] = a[:length] %}
            {% elsif a[:cstring] || a[:length] %}
              {% raise "#{e[:label]}: `cstring:`/`length:` only apply to String or Bytes elements" %}
            {% end %}
            {% e[:eopts] = {label: e[:label], width: e[:ewidth], signed: sg[1], mode: emode, length: elength, max: nil} %}
            {% if e[:cat] == :static_array %}
              {% e[:count] = t.type_vars[1] %}
              {% e[:width] = e[:ewidth] ? e[:ewidth] * t.type_vars[1] : nil %}
            {% else %}
              {% modes = 0 %}
              {% modes = modes + 1 if a[:count] %}
              {% modes = modes + 1 if a[:until] %}
              {% modes = modes + 1 if a[:sentinel] %}
              {% raise "#{e[:label]}: needs exactly one of `count:`, `until: :eof` or `sentinel:`" unless modes == 1 %}
              {% raise "#{e[:label]}: `until:` must be :eof" if a[:until] && a[:until] != :eof %}
              {% e[:max] = a[:max] || "::Binary::Format::DEFAULT_MAX_COUNT".id %}
              {% if a[:until] %}
                {% e[:amode] = :rest %}
              {% elsif a[:sentinel] %}
                {% e[:amode] = :sentinel %}
                {% e[:sentinel] = a[:sentinel] %}
              {% elsif a[:count].is_a?(SymbolLiteral) %}
                {% e[:amode] = :ref %}
                {% e[:count_ref] = a[:count].id %}
                {% e[:count] = a[:count].id %}
              {% elsif a[:count].is_a?(NumberLiteral) %}
                {% e[:amode] = :fixed %}
                {% e[:count] = a[:count] %}
                {% e[:width] = e[:ewidth] ? e[:ewidth] * a[:count] : nil %}
              {% elsif a[:count].is_a?(ProcLiteral) %}
                {% e[:amode] = :proc %}
                {% e[:count] = "(#{a[:count].body})".id %}
              {% else %}
                {% raise "#{e[:label]}: `count:` must be a field name symbol, an integer literal or a `->{ }` block" %}
              {% end %}
            {% end %}
          {% end %}
```

Change the `e[:opts]` line to:

```crystal
          {% e[:opts] = {label: e[:label], width: e[:width], signed: e[:signed], mode: e[:mode], length: e[:length], max: e[:max], amode: e[:amode], count: e[:count], sentinel: e[:sentinel], elem: e[:elem], ecat: e[:ecat], ewidth: e[:ewidth], eopts: e[:eopts]} %}
```

In the derived resolution pass, add a second block after the `length_ref` one:

```crystal
        {% if e[:count_ref] %}
          {% target = nil %}
          {% for x in entries %}
            {% target = x if x[:kind] == :field && x[:name] == e[:count_ref] %}
          {% end %}
          {% raise "#{e[:label]}: `count: :#{e[:count_ref]}` names an unknown field" unless target %}
          {% raise "#{e[:label]}: `count: :#{e[:count_ref]}` must name an integer field declared before it" unless target[:cat] == :int && target[:pos] < e[:pos] %}
          {% raise "#{target[:label]}: a derived field cannot have a default value" if target[:has_default] %}
          {% target[:derived] = true %}
          {% if e[:nilable] %}
            {% target[:write_value] = "#{target[:type]}.new(#{e[:name]}.try(&.size) || 0)".id %}
          {% else %}
            {% target[:write_value] = "#{target[:type]}.new(#{e[:name]}.size)".id %}
          {% end %}
        {% end %}
```

- [ ] **Step 6: Add read/write/size branches**

`__binary_read_scalar`, before the final `{% else %}`:

```crystal
      {% elsif cat == :nested %}
        {{type}}.read({{io}})
      {% elsif cat == :static_array %}
        {{type}}.new { __binary_read_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:eopts]}}) }
      {% elsif cat == :array %}
        begin
          {% if opts[:amode] == :rest %}
            %arr = ::Array({{opts[:elem]}}).new
            while ::Binary::Format::Codec.rest?({{io}}, {{opts[:label]}})
              %arr << __binary_read_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:eopts]}})
            end
          {% elsif opts[:amode] == :sentinel %}
            %arr = ::Array({{opts[:elem]}}).new
            loop do
              %item = __binary_read_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:eopts]}})
              break if %item == {{opts[:sentinel]}}
              %arr << %item
            end
          {% else %}
            %count = ::Binary::Format::Codec.check_count({{opts[:count]}}, {{opts[:max]}}, {{opts[:label]}})
            %arr = ::Array({{opts[:elem]}}).new(::Math.min(%count, ::Binary::Format::PRESIZE_LIMIT))
            %count.times do
              %arr << __binary_read_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:eopts]}})
            end
          {% end %}
          %arr
        end
```

`__binary_write_scalar`:

```crystal
      {% elsif cat == :nested %}
        {{value}}.write({{io}})
      {% elsif cat == :static_array %}
        {{value}}.each { |%item| __binary_write_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, %item, {{opts[:eopts]}}) }
      {% elsif cat == :array %}
        {% if opts[:amode] == :fixed || opts[:amode] == :proc %}
          ::Binary::Format::Codec.check_exact_count({{value}}.size, {{opts[:count]}}, {{opts[:label]}})
        {% end %}
        {{value}}.each { |%item| __binary_write_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, %item, {{opts[:eopts]}}) }
        {% if opts[:amode] == :sentinel %}
          __binary_write_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:sentinel]}}, {{opts[:eopts]}})
        {% end %}
```

`__binary_size_scalar`:

```crystal
      {% elsif cat == :nested %}
        {{value}}.byte_size
      {% elsif cat == :static_array || cat == :array %}
        {% if opts[:ewidth] %}
          ({{value}}.size &* {{opts[:ewidth]}})
        {% else %}
          {{value}}.sum(0) { |%item| __binary_size_scalar({{opts[:ecat]}}, {{opts[:elem]}}, %item, {{opts[:eopts]}}) }
        {% end %}
        {% if opts[:amode] == :sentinel %}
          &+ __binary_size_scalar({{opts[:ecat]}}, {{opts[:elem]}}, {{opts[:sentinel]}}, {{opts[:eopts]}})
        {% end %}
```

The `&+ sentinel_size` after the `{% end %}` continues the expression on the same line of the expansion; if the formatter or parser objects, wrap the whole branch body in parentheses.

- [ ] **Step 7: Run the spec until it passes**

Run: `bin/crystal spec spec/std/binary/format_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: 19 examples pass. Watch for: `%arr`/`%item` inside a `{% for %}` in Task 2's constructor is not an issue here because each `__binary_read_scalar` call is its own expansion. The `t.type_vars[1]` of a `StaticArray` is a `NumberLiteral`; `e[:ewidth] * t.type_vars[1]` multiplies two `NumberLiteral`s.

- [ ] **Step 8: Format and commit**

```bash
bin/crystal tool format src/binary spec/std/binary
git add src/binary/format.cr spec/std/binary/format_spec.cr
git commit -m "Binary::Format: Array, StaticArray and nested formats

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `varint:`, `if:`, `value:`, `size_of: :rest`

**Files:**
- Modify: `src/binary/format.cr`
- Test: `spec/std/binary/format_spec.cr`

**Interfaces:**
- Consumes: entry contract, derived marking.
- Produces: `e[:varint]`, `e[:if]` (ProcLiteral), `e[:value]` (ProcLiteral), `e[:size_of]`, `e[:including_self]`; generated private `__binary_size_after_<name>`; `Codec.read_varint`, `write_varint`, `varint_size`, `read_enum_varint`, `write_enum_varint`, `enum_varint_size`, `present`.

- [ ] **Step 1: Add the failing specs**

Fixtures:

```crystal
private struct Startup
  include Binary::Format
  field length : Int32, size_of: :rest, including_self: true
  field version : Int32 = 196608
  field params : Array(String), cstring: true, until: :eof
end

private struct Optional
  include Binary::Format
  field flags : UInt8
  field extra : UInt16?, if: ->{ flags & 1 != 0 }
  field name : String?, cstring: true, if: ->{ flags & 2 != 0 }
  field n : UInt8, value: ->{ flags &+ 1 }
end

private struct Varints
  include Binary::Format
  field a : UInt32, varint: true
  field b : Int64, varint: true
  field k : Kind, varint: true
  field xs : Array(Int32), count: 2, varint: true
end
```

Specs:

```crystal
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
      o.flags = 9
      o.to_slice.should eq Bytes[9, 10]
    end

    it "encodes varints, zigzag for signed types and enums" do
      v = Varints.new(a: 300, b: -1, k: :response, xs: [-2, 150])
      v.to_slice.should eq Bytes[0xAC, 0x02, 0x01, 0x02, 0x03, 0xAC, 0x02]
      v.byte_size.should eq 7
      Varints.from_slice(v.to_slice).should eq v
    end
  end
```

- [ ] **Step 2: Run the spec to verify it fails**

Expected: `Startup#length: option `size_of:` is not valid`.

- [ ] **Step 3: Add `Codec` helpers**

```crystal
      def self.read_varint(io : IO, type : T.class) : T forall T
        {% if T.name.stringify.starts_with?("Int") %}
          Binary::Varint.decode_zigzag(T, io)
        {% else %}
          Binary::Varint.decode(T, io)
        {% end %}
      end

      def self.write_varint(io : IO, value : Int::Signed) : Nil
        Binary::Varint.encode_zigzag(value, io)
      end

      def self.write_varint(io : IO, value : Int::Unsigned) : Nil
        Binary::Varint.encode(value, io)
      end

      def self.varint_size(value : Int::Signed) : Int32
        Binary::Varint.size(Binary::Zigzag.encode(value))
      end

      def self.varint_size(value : Int::Unsigned) : Int32
        Binary::Varint.size(value)
      end

      def self.read_enum_varint(io : IO, type : T.class) : T forall T
        T.new(read_varint(io, typeof(T.new(0).value)))
      end

      def self.write_enum_varint(io : IO, value : Enum) : Nil
        write_varint(io, value.value)
      end

      def self.enum_varint_size(value : Enum) : Int32
        varint_size(value.value)
      end

      def self.present(value : T?, label : String) : T forall T
        value || raise Error.new("#{label}: the field is nil but its `if:` condition is true")
      end
```

- [ ] **Step 4: Normalize the four options**

Replace the per-category `allowed` block from Task 5 (the `{% if e[:cat] == :string %} ... {% end %}` chain that follows `{% e[:signed] = sg[0] %}`) with the complete list:

```crystal
          {% if e[:cat] == :int || e[:cat] == :enum %}
            {% allowed = ["endian", "varint", "value", "if", "size_of", "including_self", "max"] %}
          {% elsif e[:cat] == :float %}
            {% allowed = ["endian", "value", "if"] %}
          {% elsif e[:cat] == :bool %}
            {% allowed = ["value", "if"] %}
          {% elsif e[:cat] == :string %}
            {% allowed = ["length", "cstring", "until", "max", "if"] %}
          {% elsif e[:cat] == :bytes %}
            {% allowed = ["length", "until", "max", "if"] %}
          {% elsif e[:cat] == :nested %}
            {% allowed = ["if"] %}
          {% elsif e[:cat] == :static_array %}
            {% allowed = ["endian", "varint", "cstring", "length", "if"] %}
          {% elsif e[:cat] == :array %}
            {% allowed = ["endian", "varint", "cstring", "length", "count", "until", "sentinel", "max", "if"] %}
          {% end %}
```

After the element/array block from Task 5, add:

```crystal
          {% e[:varint] = a[:varint] ? true : nil %}
          {% if e[:varint] %}
            {% vcat = elem ? e[:ecat] : e[:cat] %}
            {% raise "#{e[:label]}: `varint:` needs an integer or enum type" unless vcat == :int || vcat == :enum %}
            {% raise "#{e[:label]}: `varint:` cannot be combined with `size_of:`" if a[:size_of] %}
            {% if elem %}
              {% e[:ewidth] = nil %}
              {% e[:eopts] = {label: e[:label], width: nil, signed: sg[1], mode: nil, length: nil, max: nil, varint: true} %}
            {% end %}
            {% e[:width] = nil %}
          {% end %}
          {% e[:if] = nil %}
          {% if a[:if] %}
            {% raise "#{e[:label]}: `if:` expects a `->{ }` block" unless a[:if].is_a?(ProcLiteral) %}
            {% raise "#{e[:label]}: a field with `if:` must be declared nilable (`#{t}?`)" unless e[:nilable] %}
            {% e[:if] = a[:if] %}
            {% e[:width] = nil %}
          {% elsif e[:nilable] %}
            {% raise "#{e[:label]}: a nilable field needs an `if:` condition" %}
          {% end %}
          {% e[:value] = nil %}
          {% if a[:value] %}
            {% raise "#{e[:label]}: `value:` expects a `->{ }` block" unless a[:value].is_a?(ProcLiteral) %}
            {% raise "#{e[:label]}: a derived field cannot have a default value" if e[:has_default] %}
            {% e[:value] = a[:value] %}
            {% e[:derived] = true %}
            {% if e[:cat] == :int || e[:cat] == :float %}
              {% e[:write_value] = "#{t}.new((#{a[:value].body}))".id %}
            {% else %}
              {% e[:write_value] = "((#{a[:value].body}))".id %}
            {% end %}
          {% end %}
          {% e[:size_of] = nil %}
          {% if a[:size_of] %}
            {% raise "#{e[:label]}: `size_of:` must be :rest" unless a[:size_of] == :rest %}
            {% raise "#{e[:label]}: `size_of:` needs an integer type" unless e[:cat] == :int %}
            {% raise "#{e[:label]}: a derived field cannot have a default value" if e[:has_default] %}
            {% raise "#{type_name}: only one field may have `size_of: :rest`" if entries.any? { |x| x[:size_of] } %}
            {% e[:size_of] = true %}
            {% e[:including_self] = a[:including_self] ? true : false %}
            {% e[:max] = a[:max] || "::Binary::Format::DEFAULT_MAX_BYTES".id %}
            {% e[:derived] = true %}
            {% e[:write_value] = "#{t}.new(__binary_size_after_#{e[:name]}#{e[:including_self] ? " &+ #{e[:width]}" : ""})".id %}
          {% elsif a[:including_self] %}
            {% raise "#{e[:label]}: `including_self:` only applies with `size_of: :rest`" %}
          {% end %}
```

Add `varint: e[:varint]` to the `e[:opts]` NamedTupleLiteral.

- [ ] **Step 5: Wire `if:`, `size_of` and varints into the generated methods**

In `initialize(*, __binary_io __io : IO)` change the field branch to:

```crystal
          {% elsif e[:kind] == :field %}
            {{e[:name]}} = {% if e[:if] %} ({{e[:if].body}}) ? ( {% end %} __binary_read_scalar(__io, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, {{e[:opts]}}) {% if e[:if] %} ) : nil {% end %}
            {% if e[:size_of] %}
              __io = ::IO::Sized.new(__io, ::Binary::Format::Codec.check_size({{e[:name]}}{% if e[:including_self] %} &- {{e[:width]}}{% end %}, {{e[:max]}}, {{e[:label]}}))
            {% end %}
```

In `write(__io : IO)` change the field branch to:

```crystal
          {% elsif e[:kind] == :field %}
            {% if e[:if] %}
              if ({{e[:if].body}})
                __binary_write_scalar(__io, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, ::Binary::Format::Codec.present(@{{e[:name]}}, {{e[:label]}}), {{e[:opts]}})
              end
            {% else %}
              __binary_write_scalar(__io, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, {{e[:write_value] || "@#{e[:name]}".id}}, {{e[:opts]}})
            {% end %}
```

Replace the `byte_size` method with a loop that generates `byte_size` and one `__binary_size_after_<name>` per `size_of` field. Every entry has `e[:pos]` (set just before `entries << e` in Task 4, which covers pads and magics too):

```crystal
      {% size_points = [{"byte_size".id, 0}] %}
      {% for e in entries %}
        {% if e[:size_of] %}
          {% size_points << {"__binary_size_after_#{e[:name]}".id, e[:pos] + 1} %}
        {% end %}
      {% end %}
      {% for point in size_points %}
        # Returns the encoded size in bytes without writing anything.
        def {{point[0]}} : Int32
          0 {% for e in entries %}
            {% if e[:pos] >= point[1] %}
              {% if e[:kind] == :field %}
                {% if e[:if] %}
                  &+ (({{e[:if].body}}) ? __binary_size_scalar({{e[:cat]}}, {{e[:type]}}, ::Binary::Format::Codec.present(@{{e[:name]}}, {{e[:label]}}), {{e[:opts]}}) : 0)
                {% else %}
                  &+ (__binary_size_scalar({{e[:cat]}}, {{e[:type]}}, {{e[:write_value] || "@#{e[:name]}".id}}, {{e[:opts]}}))
                {% end %}
              {% else %}
                &+ {{e[:width]}}
              {% end %}
            {% end %}
          {% end %}
        end
      {% end %}
```

Varint branches in the helper macros. In `__binary_read_scalar` change the int/enum branches to:

```crystal
      {% if cat == :int || cat == :float %}
        {% if opts[:varint] %}
          ::Binary::Format::Codec.read_varint({{io}}, {{type}})
        {% else %}
          {{io}}.read_bytes({{type}}, {{format}})
        {% end %}
      {% elsif cat == :bool %}
        ::Binary::Format::Codec.read_bool({{io}})
      {% elsif cat == :enum %}
        {% if opts[:varint] %}
          ::Binary::Format::Codec.read_enum_varint({{io}}, {{type}})
        {% else %}
          ::Binary::Format::Codec.read_enum({{io}}, {{type}}, {{format}})
        {% end %}
```

In `__binary_write_scalar`:

```crystal
      {% if cat == :int || cat == :float %}
        {% if opts[:varint] %}
          ::Binary::Format::Codec.write_varint({{io}}, {{value}})
        {% else %}
          {{io}}.write_bytes({{value}}, {{format}})
        {% end %}
      {% elsif cat == :bool %}
        ::Binary::Format::Codec.write_bool({{io}}, {{value}})
      {% elsif cat == :enum %}
        {% if opts[:varint] %}
          ::Binary::Format::Codec.write_enum_varint({{io}}, {{value}})
        {% else %}
          ::Binary::Format::Codec.write_enum({{io}}, {{value}}, {{format}})
        {% end %}
```

In `__binary_size_scalar`:

```crystal
      {% if cat == :int || cat == :float || cat == :bool || cat == :enum %}
        {% if opts[:varint] && cat == :enum %}
          ::Binary::Format::Codec.enum_varint_size({{value}})
        {% elsif opts[:varint] %}
          ::Binary::Format::Codec.varint_size({{value}})
        {% else %}
          {{opts[:width]}}
        {% end %}
```

- [ ] **Step 6: Run the spec until it passes**

Run: `bin/crystal spec spec/std/binary/format_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: 26 examples pass. Notes:
- The Postgres byte dump: 4 (length) + 4 (version) + `"user\0bob\0database\0db\0\0"` (22 bytes) = 30.
- In the constructor, `value:` fields are computed after every ivar has a placeholder, so `flags &+ 1` resolves `flags` to the getter.
- `Optional.from_slice(Bytes[1, 0, 9, 2])`: `n` on read is whatever the stream says (2), not recomputed.
- If `entries.any? { |x| x[:size_of] }` complains about `nil` keys, initialize `e[:size_of] = nil` at the top of the entry block (with `e[:width] = nil`).

- [ ] **Step 7: Format and commit**

```bash
bin/crystal tool format src/binary spec/std/binary
git add src/binary/format.cr spec/std/binary/format_spec.cr
git commit -m "Binary::Format: varint, if, value and size_of options

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Packed `bits:` fields

**Files:**
- Modify: `src/binary/format.cr`
- Test: `spec/std/binary/format_spec.cr`

**Interfaces:**
- Consumes: entry contract, `bit_order`.
- Produces: `bit_order :msb|:lsb` directive; `e[:bits]`, `e[:run_head]`, `e[:run_bytes]`, `e[:run_members]`, `e[:bit_shift]`; `Codec.read_bits`, `write_bits`, `from_bits`, `to_bits`.

- [ ] **Step 1: Add the failing specs**

Fixtures:

```crystal
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
```

Specs:

```crystal
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
```

- [ ] **Step 2: Run the spec to verify it fails**

Expected: `Ipv4#version: option `bits:` is not valid`.

- [ ] **Step 3: Add the directive and `Codec` helpers**

Directive, after `macro endian`:

```crystal
    # Sets the packing order of `bits:` runs: `:msb` (default) or `:lsb`.
    macro bit_order(value)
      {% raise "Binary::Format: bit_order must be :msb or :lsb, not #{value}" unless [:msb, :lsb].includes?(value) %}
      @[::Binary::Format::Entry(kind: :bit_order, value: {{value}})]
      private def __binary_directive_bit_order; end
    end
```

Codec:

```crystal
      def self.read_bits(io : IO, nbytes : Int32, msb : Bool) : UInt64
        acc = 0_u64
        nbytes.times do |i|
          byte = io.read_byte || raise IO::EOFError.new
          if msb
            acc = (acc << 8) | byte
          else
            acc |= byte.to_u64 << (8 * i)
          end
        end
        acc
      end

      def self.write_bits(io : IO, acc : UInt64, nbytes : Int32, msb : Bool) : Nil
        nbytes.times do |i|
          shift = msb ? 8 * (nbytes - 1 - i) : 8 * i
          io.write_byte(((acc >> shift) & 0xFF).to_u8!)
        end
      end

      def self.load_bits(ptr : Pointer(UInt8), nbytes : Int32, msb : Bool) : UInt64
        acc = 0_u64
        nbytes.times do |i|
          if msb
            acc = (acc << 8) | ptr[i]
          else
            acc |= ptr[i].to_u64 << (8 * i)
          end
        end
        acc
      end

      def self.store_bits(ptr : Pointer(UInt8), acc : UInt64, nbytes : Int32, msb : Bool) : Nil
        nbytes.times do |i|
          shift = msb ? 8 * (nbytes - 1 - i) : 8 * i
          ptr[i] = ((acc >> shift) & 0xFF).to_u8!
        end
      end

      def self.from_bits(type : T.class, acc : UInt64, shift : Int32, bits : Int32) : T forall T
        raw = (acc >> shift) & (bits == 64 ? UInt64::MAX : (1_u64 << bits) &- 1)
        {% if T == ::Bool %}
          raw != 0
        {% elsif T < ::Enum %}
          T.new(typeof(T.new(0).value).new!(raw))
        {% else %}
          T.new!(raw)
        {% end %}
      end

      def self.to_bits(value : Bool, bits : Int32, label : String) : UInt64
        value ? 1_u64 : 0_u64
      end

      def self.to_bits(value : Enum, bits : Int32, label : String) : UInt64
        to_bits(value.value, bits, label)
      end

      def self.to_bits(value : Int, bits : Int32, label : String) : UInt64
        raw = value.to_u64!
        if value < 0 || (bits < 64 && raw >= (1_u64 << bits))
          raise Error.new("#{label}: value #{value} does not fit in #{bits} bits")
        end
        raw
      end
```

- [ ] **Step 4: Normalize runs inside the entry loop**

In the directive collection loop at the top of `__binary_generate`, add `{% bit_order = :msb %}` next to `type_endian` and a branch `{% elsif a[:kind] == :bit_order %} {% bit_order = a[:value] %}`.

Add `"bits"` to the `allowed` lists of the `:int`/`:enum` case and of the `:bool` case in the block from Task 6 (floats keep rejecting `bits:`).

Declare the run state before the `{% for a in raw %}` loop:

```crystal
      {% run = [] of Nil %}
      {% run_offset = nil %}
```

Inside the entry block for fields, after the `size_of` block, add:

```crystal
          {% e[:bits] = nil %}
          {% if a[:bits] %}
            {% raise "#{e[:label]}: `bits:` expects an integer literal in 1..64" unless a[:bits].is_a?(NumberLiteral) && a[:bits] >= 1 && a[:bits] <= 64 %}
            {% raise "#{e[:label]}: `bits: #{a[:bits]}` is wider than #{t}" if e[:width] && a[:bits] > e[:width] * 8 %}
            {% raise "#{e[:label]}: `bits:` cannot be combined with `varint:`, `if:` or `size_of:`" if e[:varint] || e[:if] || e[:size_of] %}
            {% e[:bits] = a[:bits] %}
            {% e[:width] = 0 %}
          {% end %}
```

Replace the block that updates `fixed`/`offset` (the `{% if e[:width].nil? %} ... {% end %}` just before `{% e[:pos] = entries.size %}`) with:

```crystal
        {% if e[:kind] == :field && e[:bits] %}
          {% run_offset = offset if run.empty? %}
          {% e[:offset] = run_offset %}
          {% run << e %}
        {% else %}
          {% if !run.empty? %}
            {% total = 0 %}
            {% for m in run %}
              {% total = total + m[:bits] %}
            {% end %}
            {% raise "#{run[0][:label]}: a run of `bits:` fields must end on a byte boundary, this one has #{total} bits" unless total % 8 == 0 %}
            {% raise "#{run[0][:label]}: a run of `bits:` fields may not exceed 64 bits, this one has #{total} bits" if total > 64 %}
            {% shift = 0 %}
            {% for m, i in run %}
              {% m[:run_head] = i == 0 %}
              {% m[:run_bytes] = total / 8 %}
              {% m[:bit_shift] = bit_order == :msb ? total - shift - m[:bits] : shift %}
              {% shift = shift + m[:bits] %}
            {% end %}
            {% run[0][:run_members] = run %}
            {% run[0][:width] = total / 8 %}
            {% offset = run_offset + total / 8 if run_offset %}
            {% run = [] of Nil %}
          {% end %}
          {% if e[:width].nil? %}
            {% fixed = false %}
            {% offset = nil %}
          {% elsif offset %}
            {% e[:offset] = offset %}
            {% offset = offset + e[:width] %}
          {% end %}
        {% end %}
```

The run must also be closed when it is the last entry. After the `{% for a in raw %} ... {% end %}` loop, duplicate the closing block once more (the `{% if !run.empty? %} ... {% end %}` part only, verbatim), so a trailing run gets its head marked and `offset` advanced.

`total / 8` on `NumberLiteral`s yields an integer literal when both sides are integers.

- [ ] **Step 5: Generate run code**

In `initialize(*, __binary_io __io : IO)` add a branch before the plain field branch:

```crystal
          {% elsif e[:kind] == :field && e[:bits] && !e[:run_head] %}
          {% elsif e[:kind] == :field && e[:bits] %}
            %acc{e[:name]} = ::Binary::Format::Codec.read_bits(__io, {{e[:run_bytes]}}, {{bit_order == :msb}})
            {% for m in e[:run_members] %}
              {{m[:name]}} = ::Binary::Format::Codec.from_bits({{m[:type]}}, %acc{e[:name]}, {{m[:bit_shift]}}, {{m[:bits]}})
            {% end %}
```

In `write(__io : IO)` add before the plain field branch:

```crystal
          {% elsif e[:kind] == :field && e[:bits] && !e[:run_head] %}
          {% elsif e[:kind] == :field && e[:bits] %}
            %acc{e[:name]} = 0_u64
            {% for m in e[:run_members] %}
              %acc{e[:name]} |= ::Binary::Format::Codec.to_bits({{m[:write_value] || "@#{m[:name]}".id}}, {{m[:bits]}}, {{m[:label]}}) << {{m[:bit_shift]}}
            {% end %}
            ::Binary::Format::Codec.write_bits(__io, %acc{e[:name]}, {{e[:run_bytes]}}, {{bit_order == :msb}})
```

In the size-point loop, add before the `{% if e[:if] %}` branch: `{% if e[:bits] %} &+ {{e[:width]}} {% elsif e[:if] %} ...` (a run head contributes `run_bytes`, members contribute 0).

- [ ] **Step 6: Run the spec until it passes**

Run: `bin/crystal spec spec/std/binary/format_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: 29 examples pass. If `{% for m, i in run %}` does not mutate the shared hashes, mark heads by name instead: keep a `heads = [] of Nil` list of names and look up `e[:name]` membership in the codegen loops.

- [ ] **Step 7: Format and commit**

```bash
bin/crystal tool format src/binary spec/std/binary
git add src/binary/format.cr spec/std/binary/format_spec.cr
git commit -m "Binary::Format: packed bit fields with bit_order

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Fixed layouts: `SIZE`, pointer decode/encode, single read and write

**Files:**
- Modify: `src/binary/format.cr`
- Test: `spec/std/binary/format_spec.cr`

**Interfaces:**
- Consumes: `fixed`, `offset`, `e[:offset]`, `e[:width]`, run info.
- Produces: for fixed formats `SIZE : Int32`, `self.fixed_size? == true`, `self.read(io)` via one `read_fully`, `self.from_slice(bytes)` / `(bytes, offset)` by pointer, `write_to(bytes : Bytes) : Int32`, `write(io)` via one `io.write`, `byte_size == SIZE`, `to_slice`; helper macros `__binary_decode_scalar(ptr, cat, type, format, opts)` and `__binary_encode_scalar(ptr, cat, type, format, value, opts)`; `Codec.decode_enum`, `encode_enum`, `zero_fill`.

- [ ] **Step 1: Add the failing specs**

Add a counting IO helper at the top of the spec file:

```crystal
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
```

Fixtures:

```crystal
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
```

Specs:

```crystal
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
```

- [ ] **Step 2: Run the spec to verify it fails**

Expected: `undefined constant Header::SIZE`.

- [ ] **Step 3: Add `Codec` helpers and the decode/encode macros**

Codec:

```crystal
      def self.decode_enum(type : T.class, bytes : Bytes, format : IO::ByteFormat) : T forall T
        T.new(format.decode(typeof(T.new(0).value), bytes))
      end

      def self.encode_enum(value : Enum, bytes : Bytes, format : IO::ByteFormat) : Nil
        format.encode(value.value, bytes)
      end

      def self.zero_fill(ptr : Pointer(UInt8), count : Int32) : Nil
        ptr.clear(count)
      end

      def self.copy_exact(value : Bytes, ptr : Pointer(UInt8), size : Int32, label : String) : Nil
        raise Error.new("#{label}: expected #{size} bytes but the value has #{value.size}") unless value.size == size
        value.copy_to(ptr, size)
      end
```

Helper macros, after `__binary_size_scalar`:

```crystal
    # :nodoc:
    macro __binary_decode_scalar(ptr, cat, type, format, opts)
      {% if cat == :int || cat == :float %}
        {{format}}.decode({{type}}, ::Slice.new({{ptr}}, {{opts[:width]}}))
      {% elsif cat == :bool %}
        ({{ptr}}.value != 0)
      {% elsif cat == :enum %}
        ::Binary::Format::Codec.decode_enum({{type}}, ::Slice.new({{ptr}}, {{opts[:width]}}), {{format}})
      {% elsif cat == :string %}
        ::String.new(::Slice.new({{ptr}}, {{opts[:width]}}))
      {% elsif cat == :bytes %}
        ::Slice.new({{ptr}}, {{opts[:width]}}).dup
      {% elsif cat == :nested %}
        {{type}}.from_slice(::Slice.new({{ptr}}, {{opts[:width]}}))
      {% elsif cat == :static_array %}
        {{type}}.new { |%i| __binary_decode_scalar({{ptr}} + %i &* {{opts[:ewidth]}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:eopts]}}) }
      {% elsif cat == :array %}
        ::Array({{opts[:elem]}}).new({{opts[:count]}}) { |%i| __binary_decode_scalar({{ptr}} + %i &* {{opts[:ewidth]}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:eopts]}}) }
      {% else %}
        {% raise "Binary::Format: cannot decode #{cat} from a pointer" %}
      {% end %}
    end

    # :nodoc:
    macro __binary_encode_scalar(ptr, cat, type, format, value, opts)
      {% if cat == :int || cat == :float %}
        {{format}}.encode({{value}}, ::Slice.new({{ptr}}, {{opts[:width]}}))
      {% elsif cat == :bool %}
        {{ptr}}.value = ({{value}} ? 1_u8 : 0_u8)
      {% elsif cat == :enum %}
        ::Binary::Format::Codec.encode_enum({{value}}, ::Slice.new({{ptr}}, {{opts[:width]}}), {{format}})
      {% elsif cat == :string || cat == :bytes %}
        ::Binary::Format::Codec.copy_exact({{value}}.to_slice, {{ptr}}, {{opts[:width]}}, {{opts[:label]}})
      {% elsif cat == :nested %}
        {{value}}.write_to(::Slice.new({{ptr}}, {{opts[:width]}}))
      {% elsif cat == :static_array %}
        {{value}}.each_with_index { |%item, %i| __binary_encode_scalar({{ptr}} + %i &* {{opts[:ewidth]}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, %item, {{opts[:eopts]}}) }
      {% elsif cat == :array %}
        ::Binary::Format::Codec.check_exact_count({{value}}.size, {{opts[:count]}}, {{opts[:label]}})
        {{value}}.each_with_index { |%item, %i| __binary_encode_scalar({{ptr}} + %i &* {{opts[:ewidth]}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, %item, {{opts[:eopts]}}) }
      {% else %}
        {% raise "Binary::Format: cannot encode #{cat} to a pointer" %}
      {% end %}
    end
```

`IO::ByteFormat.decode(Float32.class, bytes : Bytes)` and the `Float64` overload exist alongside the integer ones; `encode(Float32, bytes)` too.

- [ ] **Step 4: Branch the generated methods on `fixed`**

Wrap the existing variable-layout generated methods (`self.read`, both `self.from_slice`, `initialize(*, __binary_io ...)`, `write`, the size-point loop, `to_slice`) in `{% unless fixed %} ... {% end %}` and add, inside `{% if fixed %} ... {% end %}`:

```crystal
      {% if fixed %}
        # Encoded size in bytes of every record of this format.
        SIZE = {{offset}}

        # Reads one record from *io* with a single `read_fully`.
        def self.read(io : IO) : self
          buf = uninitialized UInt8[SIZE]
          io.read_fully(buf.to_slice)
          new(__binary_ptr: buf.to_unsafe)
        end

        # Decodes one record from the start of *bytes* without copying.
        def self.from_slice(bytes : Bytes) : self
          raise IO::EOFError.new if bytes.size < SIZE
          new(__binary_ptr: bytes.to_unsafe)
        end

        # Decodes one record at *offset* and returns it with `SIZE`.
        def self.from_slice(bytes : Bytes, offset : Int) : {self, Int32}
          raise IO::EOFError.new if offset < 0 || bytes.size - offset < SIZE
          {new(__binary_ptr: bytes.to_unsafe + offset), SIZE}
        end

        # :nodoc:
        def initialize(*, __binary_ptr __ptr : Pointer(UInt8))
          {% for e in entries %}
            {% if e[:kind] == :magic %}
              ::Binary::Format::Codec.check_magic(::Slice.new(__ptr + {{e[:offset]}}, {{e[:width]}}), BINARY_MAGIC_{{e[:index]}}, {{type_name}})
            {% elsif e[:kind] == :field && e[:bits] && !e[:run_head] %}
            {% elsif e[:kind] == :field && e[:bits] %}
              %acc{e[:name]} = ::Binary::Format::Codec.load_bits(__ptr + {{e[:offset]}}, {{e[:run_bytes]}}, {{bit_order == :msb}})
              {% for m in e[:run_members] %}
                {{m[:name]}} = ::Binary::Format::Codec.from_bits({{m[:type]}}, %acc{e[:name]}, {{m[:bit_shift]}}, {{m[:bits]}})
              {% end %}
            {% elsif e[:kind] == :field %}
              {{e[:name]}} = __binary_decode_scalar(__ptr + {{e[:offset]}}, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, {{e[:opts]}})
            {% end %}
          {% end %}
          {% for e in fields %}
            @{{e[:name]}} = {{e[:name]}}
          {% end %}
        end

        # Encodes this record into the first `SIZE` bytes of *bytes* and
        # returns `SIZE`. Raises `ArgumentError` if *bytes* is too small.
        def write_to(bytes : Bytes) : Int32
          raise ArgumentError.new("need #{SIZE} bytes, got #{bytes.size}") if bytes.size < SIZE
          __ptr = bytes.to_unsafe
          {% for e in entries %}
            {% if e[:kind] == :pad %}
              {% if e[:width] > 0 %} ::Binary::Format::Codec.zero_fill(__ptr + {{e[:offset]}}, {{e[:width]}}) {% end %}
            {% elsif e[:kind] == :magic %}
              BINARY_MAGIC_{{e[:index]}}.copy_to(__ptr + {{e[:offset]}}, {{e[:width]}})
            {% elsif e[:kind] == :field && e[:bits] && !e[:run_head] %}
            {% elsif e[:kind] == :field && e[:bits] %}
              %acc{e[:name]} = 0_u64
              {% for m in e[:run_members] %}
                %acc{e[:name]} |= ::Binary::Format::Codec.to_bits({{m[:write_value] || "@#{m[:name]}".id}}, {{m[:bits]}}, {{m[:label]}}) << {{m[:bit_shift]}}
              {% end %}
              ::Binary::Format::Codec.store_bits(__ptr + {{e[:offset]}}, %acc{e[:name]}, {{e[:run_bytes]}}, {{bit_order == :msb}})
            {% elsif e[:kind] == :field %}
              __binary_encode_scalar(__ptr + {{e[:offset]}}, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, {{e[:write_value] || "@#{e[:name]}".id}}, {{e[:opts]}})
            {% end %}
          {% end %}
          SIZE
        end

        # Writes this record to *io* with a single `write`.
        def write(io : IO) : Nil
          buf = uninitialized UInt8[SIZE]
          write_to(buf.to_slice)
          io.write(buf.to_slice)
        end

        # Returns `SIZE`.
        def byte_size : Int32
          SIZE
        end

        # Returns this record encoded into a new `Bytes` of `SIZE` bytes.
        def to_slice : Bytes
          bytes = Bytes.new(SIZE)
          write_to(bytes)
          bytes
        end
      {% end %}
```

Pads in the pointer read path need no code (bytes are skipped by offset). `e[:offset]` is set for every entry when the layout is fixed, including run members (all members share the head's offset).

- [ ] **Step 5: Run the spec until it passes**

Run: `bin/crystal spec spec/std/binary/format_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: 34 examples pass. The earlier specs for `Header`, `Mixed`, `PngSig`, `Riff`, `Aligned`, `Ipv4`, `LsbBits` now exercise the pointer path; all must still pass byte-for-byte. `Point` is fixed, so `Shapes` embeds it through `Point.read(io)` in the variable path and `Elf64Ident` through `Point.from_slice`/`write_to` in the fixed path.

- [ ] **Step 6: Format and commit**

```bash
bin/crystal tool format src/binary spec/std/binary
git add src/binary/format.cr spec/std/binary/format_spec.cr
git commit -m "Binary::Format: fixed layouts with SIZE, pointer decode and single-write IO

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Known-answer fixtures, error paths, random round-trips

**Files:**
- Test: `spec/std/binary/format_spec.cr`

**Interfaces:**
- Consumes: everything generated so far. No production code changes expected; any failure here is a bug to fix in `format.cr` with a note in the commit.

- [ ] **Step 1: Add the Postgres and RPC fixtures**

```crystal
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
  field value : Bytes?, length: :length, if: ->{ length >= 0 }
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
```

`PgColumn` combines `length: :length` with `if:` on the value, so `length` is derived: `Int32.new(value.try(&.size) || 0)`. A `nil` value therefore writes a `0` length, while a `-1` on the wire reads back as `nil` because the `if:` condition is false. The Postgres client (Tier 3a) will write NULL columns through its own encoder if it needs `-1` on the wire; nothing in the format module changes for that.

- [ ] **Step 2: Add the specs**

```crystal
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
      row = PgDataRow.new(columns: [PgColumn.new(value: "42".to_slice), PgColumn.new(value: nil)])
      bytes = row.to_slice
      bytes.should eq Bytes[0x44, 0, 0, 0, 18, 0, 2, 0, 0, 0, 2, 0x34, 0x32, 0, 0, 0, 0]
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
        t = Texts.new(name: t.name, tag: t.tag, note: t.note, n: t.n, twice: Bytes.new(t.n * 2) { rng.rand(UInt8) }, rest: t.rest)
        Texts.from_slice(t.to_slice).should eq t
      end
    end
  end
```

- [ ] **Step 3: Run the spec**

Run: `bin/crystal spec spec/std/binary/format_spec.cr 2>&1 | grep -v "ld64.lld\|Using compiled"`
Expected: 40 examples pass. The NULL-column dump encodes the derived `0` length on write (`0, 0, 0, 0`) and reads the `-1` form back as `nil` with `length == -1`.

- [ ] **Step 4: Format and commit**

```bash
bin/crystal tool format spec/std/binary
git add spec/std/binary/format_spec.cr src/binary/format.cr
git commit -m "Binary::Format: known-answer and random round-trip specs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Module docs, compile-error script, formatting, full suite

**Files:**
- Modify: `src/binary/format.cr` (module doc comment), `src/binary.cr` (module doc line)
- Create: `.remember/harness-2026-09-17/format/compile_errors.sh` (gitignored)

- [ ] **Step 1: Write the module doc comment**

Replace the one-line comment above `module Format` with:

```crystal
  # Declarative layout for binary structs and protocol messages.
  #
  # Including `Binary::Format` in a `struct` or `class` and declaring the
  # layout with `field` (plus `pad`, `align`, `magic`) generates a keyword
  # constructor, `read(io)`, `from_slice`, `write(io)`, `to_slice` and
  # `byte_size`:
  #
  # ```
  # require "binary"
  #
  # struct PngHeader
  #   include Binary::Format
  #   magic Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  #   field width : UInt32
  #   field height : UInt32
  #   field depth : UInt8
  #   pad 3
  # end
  #
  # header = PngHeader.new(width: 640, height: 480, depth: 8)
  # header.to_slice.size # => 20
  # PngHeader.from_slice(header.to_slice).width # => 640
  # ```
  #
  # ### Directives
  #
  # * `endian :big | :little | :native`: default byte order (default `:big`).
  # * `bit_order :msb | :lsb`: packing order of `bits:` runs (default `:msb`).
  #
  # ### Entries
  #
  # * `field name : Type[, options]`, optionally `= default`.
  # * `pad n`: skips *n* bytes on read, writes zeros.
  # * `align n`: pads to a multiple of *n* bytes from the record start; every
  #   entry before it must have a fixed width.
  # * `magic value`: constant bytes (`String` ASCII, `Bytes[...]`, or a
  #   suffixed integer literal); a mismatch on read raises `MagicError`.
  #
  # ### Field types
  #
  # Integers, `Float32`/`Float64`, `Bool` (one byte), enums, `String`,
  # `Bytes`, `StaticArray(T, N)`, `Array(T)`, nested formats (which must be
  # defined earlier in the file), and `T?` together with `if:`.
  #
  # ### Field options
  #
  # * `endian:`: per-field byte order.
  # * `varint: true`: LEB128 for unsigned types, zigzag for signed types.
  # * `bits: n`: packed bit field; consecutive `bits:` fields form a run that
  #   must end on a byte boundary and fit in 64 bits.
  # * `length: :other | n | ->{ expr }`: byte length of a `String`/`Bytes`.
  #   A field name makes that integer field *derived*: it is computed on
  #   write and excluded from the constructor.
  # * `cstring: true`: NUL-terminated `String` (also per element of an array).
  # * `count: :other | n | ->{ expr }`: element count of an `Array`.
  # * `until: :eof`: consume the rest of the bounding stream (needs an IO with
  #   `peek` for arrays).
  # * `sentinel: value`: read array elements until one equals *value*.
  # * `size_of: :rest`: the field holds the byte size of everything after it
  #   and bounds the read of the rest; `including_self: true` adds its own
  #   width. Derived.
  # * `value: ->{ expr }`: derived field computed on write.
  # * `if: ->{ expr }`: the field is present only when *expr* is true; the
  #   type must be nilable.
  # * `max: n`: allocation guard for length and count prefixes.
  #
  # Expressions in `->{ }` refer to earlier fields by name.
  #
  # Derived fields are recomputed on every `write`; setters do not update
  # them.
  #
  # ### Fixed layouts
  #
  # When every entry has a compile-time width the format is *fixed*: it gets
  # a `SIZE` constant, `fixed_size?` returns `true`, `from_slice` decodes by
  # pointer offset, `write_to(bytes)` encodes in place, and `read`/`write`
  # use a single IO call.
  #
  # ### Errors
  #
  # `Error` for invalid values (a NUL inside a cstring, a value too wide for
  # its bits, a required `if:` field that is `nil`), `MagicError`,
  # `SizeError` for prefixes beyond `max:`, and `IO::EOFError` for truncated
  # input.
```

Update the first comment line of `src/binary.cr` to mention bit IO and formats:

```crystal
# Format-agnostic building blocks for binary protocols and file formats:
# variable-length integers (`Binary::Varint`, `Binary::Zigzag`),
# length-prefixed framing (`Binary::Frame`), bit-level IO
# (`Binary::BitReader`, `Binary::BitWriter`) and declarative struct layouts
# (`Binary::Format`).
```

- [ ] **Step 2: Write the compile-error script**

```bash
#!/bin/sh
# Checks that invalid layouts fail with the expected macro messages.
# Usage: .remember/harness-2026-09-17/format/compile_errors.sh (from repo root)
set -u
dir=$(mktemp -d)
fail=0
check() {
  name=$1; expected=$2; body=$3
  printf 'require "binary"\nstruct T\n  include Binary::Format\n%s\nend\nT\n' "$body" > "$dir/$name.cr"
  out=$(bin/crystal build --no-codegen "$dir/$name.cr" 2>&1)
  if printf '%s' "$out" | grep -q "$expected"; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected'"; printf '%s\n' "$out" | grep -v "ld64.lld\|Using compiled" | head -5; fail=1
  fi
}
check unknown_option "option \`foo:\` is not valid" '  field a : UInt8, foo: 1'
check string_mode "needs exactly one of" '  field s : String'
check bytes_mode "needs exactly one of" '  field b : Bytes, cstring: true'
check if_not_nilable "must be declared nilable" '  field a : UInt8, if: ->{ true }'
check nilable_without_if "needs an \`if:\` condition" '  field a : UInt8?'
check size_of_not_int "needs an integer type" '  field a : String, cstring: true, size_of: :rest'
check derived_default "cannot have a default value" '  field n : UInt8 = 1
  field s : String, length: :n'
check two_size_of "only one field may have" '  field a : UInt32, size_of: :rest
  field b : UInt32, size_of: :rest'
check bits_boundary "must end on a byte boundary" '  field a : UInt8, bits: 3'
check bits_too_wide "is wider than UInt8" '  field a : UInt8, bits: 9
  field b : UInt8, bits: 7'
check bits_over_64 "may not exceed 64 bits" '  field a : UInt64, bits: 64
  field b : UInt8, bits: 8'
check varint_float "needs an integer or enum type" '  field a : Float32, varint: true'
check magic_no_suffix "needs a type suffix" '  magic 0x1234'
check align_variable "needs every preceding entry" '  field s : String, cstring: true
  align 4'
check nested_order "must be defined before" '  field p : Later
end
struct Later
  include Binary::Format
  field a : UInt8'
check length_unknown "names an unknown field" '  field s : String, length: :nope'
check length_after "declared before it" '  field s : String, length: :n
  field n : UInt8'
rm -rf "$dir"
exit $fail
```

Run: `sh .remember/harness-2026-09-17/format/compile_errors.sh`
Expected: every line `ok`. A `FAIL` means the macro message text differs from the plan; align the message in `format.cr` (the plan's wording is the contract), not the script.

- [ ] **Step 3: Format check and full suites**

```bash
make format check=1 2>&1 | tail -3
bin/crystal spec spec/std/binary/ 2>&1 | grep -v "ld64.lld\|Using compiled" | tail -3
make std_spec 2>&1 | grep -v "ld64.lld" | tail -5
```

Expected: format clean; the `binary` directory suites green; `std_spec` shows only the known 14 environment failures (TCPSocket/iconv) and no new failures. Run `make std_spec` in the background (`run_in_background`) since it takes several minutes, and do not start another build meanwhile.

- [ ] **Step 4: Commit**

```bash
git add src/binary/format.cr src/binary.cr
git commit -m "Binary::Format: module documentation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Benchmarks against Rust `binrw` and Go `encoding/binary`

**Files:**
- Create (gitignored): `.remember/harness-2026-09-17/format/bench_format.cr`, `bench_format.rs` (+ `Cargo.toml`), `bench_format.go`, `README.md`

- [ ] **Step 1: Write the Crystal bench**

```crystal
# .remember/harness-2026-09-17/format/bench_format.cr
require "binary"
require "benchmark"

struct RpcHeader
  include Binary::Format
  field type : UInt8
  field flags : UInt8
  field stream_id : UInt32
  field length : UInt32
end

struct Column
  include Binary::Format
  field length : Int32
  field value : Bytes?, length: :length, if: ->{ length >= 0 }
end

struct DataRow
  include Binary::Format
  field type : UInt8 = 'D'.ord.to_u8
  field length : Int32, size_of: :rest, including_self: true
  field count : Int16
  field columns : Array(Column), count: :count
end

header = RpcHeader.new(type: 1, flags: 2, stream_id: 3, length: 4)
header_bytes = header.to_slice
row = DataRow.new(columns: Array.new(10) { |i| Column.new(value: "value-#{i}".to_slice) })
row_bytes = row.to_slice
buf = Bytes.new(64)
sink = IO::Memory.new(4096)

Benchmark.ips do |x|
  x.report("header from_slice") { RpcHeader.from_slice(header_bytes) }
  x.report("header write_to") { header.write_to(buf) }
  x.report("header write(io)") { sink.rewind; header.write(sink) }
  x.report("datarow from_slice") { DataRow.from_slice(row_bytes) }
  x.report("datarow write(io)") { sink.rewind; row.write(sink) }
  x.report("datarow to_slice") { row.to_slice }
end
```

Run: `bin/crystal build --release .remember/harness-2026-09-17/format/bench_format.cr -o /tmp/bench_format && /tmp/bench_format`

- [ ] **Step 2: Write the Rust bench**

`Cargo.toml`:

```toml
[package]
name = "bench_format"
version = "0.1.0"
edition = "2021"

[dependencies]
binrw = "0.14"

[[bin]]
name = "bench_format"
path = "bench_format.rs"

[profile.release]
lto = true
codegen-units = 1
```

`bench_format.rs`:

```rust
use binrw::{binrw, BinRead, BinWrite};
use std::io::Cursor;
use std::time::Instant;

#[binrw]
#[brw(big)]
#[derive(Clone, Debug, PartialEq)]
struct RpcHeader { r#type: u8, flags: u8, stream_id: u32, length: u32 }

#[binrw]
#[brw(big)]
#[derive(Clone, Debug, PartialEq)]
struct Column {
    #[bw(calc = value.as_ref().map(|v| v.len() as i32).unwrap_or(-1))]
    length: i32,
    #[br(if(length >= 0), count = length)]
    value: Option<Vec<u8>>,
}

#[binrw]
#[brw(big)]
#[derive(Clone, Debug, PartialEq)]
struct DataRow {
    #[bw(calc = b'D')]
    #[br(temp)]
    r#type: u8,
    #[bw(calc = 4 + 2 + columns.iter().map(|c| 4 + c.value.as_ref().map(|v| v.len()).unwrap_or(0)).sum::<usize>() as i32)]
    #[br(temp)]
    length: i32,
    #[bw(calc = columns.len() as i16)]
    #[br(temp)]
    count: i16,
    #[br(count = count)]
    columns: Vec<Column>,
}

fn bench<F: FnMut()>(name: &str, mut f: F) {
    let iters = 2_000_000u32;
    for _ in 0..200_000 { f(); }
    let t = Instant::now();
    for _ in 0..iters { f(); }
    let ns = t.elapsed().as_nanos() as f64 / iters as f64;
    println!("{name:24} {ns:8.1} ns/op");
}

fn main() {
    let header = RpcHeader { r#type: 1, flags: 2, stream_id: 3, length: 4 };
    let mut hb = Cursor::new(Vec::new());
    header.write(&mut hb).unwrap();
    let header_bytes = hb.into_inner();
    let row = DataRow { columns: (0..10).map(|i| Column { value: Some(format!("value-{i}").into_bytes()) }).collect() };
    let mut rb = Cursor::new(Vec::new());
    row.write(&mut rb).unwrap();
    let row_bytes = rb.into_inner();
    let mut out = Vec::with_capacity(4096);

    bench("header read", || { std::hint::black_box(RpcHeader::read(&mut Cursor::new(&header_bytes)).unwrap()); });
    bench("header write", || { out.clear(); header.write(&mut Cursor::new(&mut out)).unwrap(); });
    bench("datarow read", || { std::hint::black_box(DataRow::read(&mut Cursor::new(&row_bytes)).unwrap()); });
    bench("datarow write", || { out.clear(); row.write(&mut Cursor::new(&mut out)).unwrap(); });
}
```

Run: `cd .remember/harness-2026-09-17/format && cargo run --release --quiet`

- [ ] **Step 3: Write the Go bench**

```go
// bench_format.go
package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"testing"
)

type RpcHeader struct {
	Type, Flags uint8
	StreamID, Length uint32
}

type Column struct{ Value []byte }
type DataRow struct{ Columns []Column }

func (r *DataRow) Write(w *bytes.Buffer) {
	total := 4 + 2
	for _, c := range r.Columns {
		total += 4 + len(c.Value)
	}
	w.WriteByte('D')
	binary.Write(w, binary.BigEndian, int32(total))
	binary.Write(w, binary.BigEndian, int16(len(r.Columns)))
	for _, c := range r.Columns {
		binary.Write(w, binary.BigEndian, int32(len(c.Value)))
		w.Write(c.Value)
	}
}

func ReadDataRow(b []byte) DataRow {
	n := int(int16(binary.BigEndian.Uint16(b[5:])))
	p := 7
	cols := make([]Column, 0, n)
	for i := 0; i < n; i++ {
		l := int(int32(binary.BigEndian.Uint32(b[p:])))
		p += 4
		v := make([]byte, l)
		copy(v, b[p:p+l])
		p += l
		cols = append(cols, Column{v})
	}
	return DataRow{cols}
}

func main() {
	h := RpcHeader{1, 2, 3, 4}
	var hb bytes.Buffer
	binary.Write(&hb, binary.BigEndian, h)
	row := DataRow{}
	for i := 0; i < 10; i++ {
		row.Columns = append(row.Columns, Column{[]byte(fmt.Sprintf("value-%d", i))})
	}
	var rb bytes.Buffer
	row.Write(&rb)
	rowBytes := rb.Bytes()
	buf := make([]byte, 64)
	report := func(name string, f func()) {
		r := testing.Benchmark(func(b *testing.B) { for i := 0; i < b.N; i++ { f() } })
		fmt.Printf("%-24s %8.1f ns/op\n", name, float64(r.NsPerOp()))
	}
	report("header read", func() {
		var x RpcHeader
		x.Type, x.Flags = hb.Bytes()[0], hb.Bytes()[1]
		x.StreamID = binary.BigEndian.Uint32(hb.Bytes()[2:])
		x.Length = binary.BigEndian.Uint32(hb.Bytes()[6:])
	})
	report("header write", func() {
		buf[0], buf[1] = h.Type, h.Flags
		binary.BigEndian.PutUint32(buf[2:], h.StreamID)
		binary.BigEndian.PutUint32(buf[6:], h.Length)
	})
	report("datarow read", func() { ReadDataRow(rowBytes) })
	var out bytes.Buffer
	report("datarow write", func() { out.Reset(); row.Write(&out) })
}
```

Run: `cd .remember/harness-2026-09-17/format && go run bench_format.go`

- [ ] **Step 4: Record results in `README.md`**

Write a table with ns/op for Crystal, Rust and Go per operation and the ratio Crystal/Rust. Targets from the spec: fixed header within 10% of Rust, DataRow within 30%. If the Crystal fixed path misses the target, check the `--release` build used `bin/crystal` (LLVM 22 pin in `Makefile.local`) and inspect the generated code by adding `--emit llvm-ir` for `RpcHeader.from_slice`; the expected shape is four loads with byte swaps and no calls. If the variable path misses, profile `Column` reads: the `Bytes.new` + `read_fully` per column should be the only allocations.

- [ ] **Step 5: Update memory and handoff**

Append the results to the perf memory file at `/Users/radha/.claude/projects/-Users-radha-projects-crystal/memory/stdlib-batteries-direction.md` (one line: what shipped, commit range, bench ratios, lessons) and update its index line in `MEMORY.md`. No commit for this step (the memory lives outside the repo; the harness directory is gitignored).

---

## Self-review notes

- Spec coverage: section 1 (Tasks 2 to 7), section 2 (Tasks 2, 4, 6), section 3 (Tasks 1, 7), section 4 (Tasks 3, 4, 8), section 5 (Tasks 9, 10, 11). `align` semantics narrowed to "every preceding entry has a fixed width", which the spec's "counted from the start of the record" allows and the compile-error script checks.
- Not in scope, as the spec says: inheritance, tuples, `Char`, peek-based terminators, bit runs over 64 bits, `IO#read_bytes(T)` overloads.
- Type consistency: `e[:opts]` keys used by helper macros are `label`, `width`, `signed`, `mode`, `length`, `max`, `amode`, `count`, `sentinel`, `elem`, `ecat`, `ewidth`, `eopts`, `varint`. `eopts` carries `label`, `width`, `signed`, `mode`, `length`, `max`, `varint`. `Codec` method names are used exactly as defined in the task that introduces them.
