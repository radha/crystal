module Binary
  # Variable-length integer encoding (unsigned LEB128, as used by Protocol
  # Buffers, WebAssembly and DWARF).
  #
  # Each byte carries seven bits of the value, least significant group first,
  # with the high bit set on every byte except the last. Values up to 127 take
  # one byte; a `UInt64` takes at most ten.
  #
  # Unsigned integers encode their magnitude. Signed integers encode their
  # 64-bit two's complement, so a negative value always takes ten bytes (this
  # is Protocol Buffers' `int64`). Use `Zigzag`, `.encode_zigzag` and
  # `.decode_zigzag` for a signed encoding where small negative values stay
  # small (Protocol Buffers' `sint64`).
  #
  # ```
  # require "binary"
  #
  # io = IO::Memory.new
  # io.write_varint(300) # => 2
  # io.to_slice          # => Bytes[0xac, 0x02]
  # io.rewind
  # io.read_varint(UInt32) # => 300
  #
  # Binary::Varint.decode(UInt64, Bytes[0xac, 0x02, 0xff]) # => {300, 2}
  # ```
  #
  # Decoding rejects encodings longer than ten bytes or whose tenth byte
  # carries more than the last bit of a `UInt64`, and values that do not fit
  # the requested type. Non-canonical encodings with trailing zero groups
  # (`Bytes[0x80, 0x00]` for `0`) are accepted unless `strict: true`.
  module Varint
    # Raised when an encoding is malformed or its value does not fit the
    # requested type.
    class Error < Binary::Error
    end

    # The maximum number of bytes a 64-bit varint occupies.
    MAX_SIZE = 10

    # Returns the number of bytes `.encode` writes for *value*.
    def self.size(value : Int::Unsigned) : Int32
      size_u64(value.to_u64)
    end

    # :ditto:
    def self.size(value : Int::Signed) : Int32
      size_u64(value.to_i64.to_u64!)
    end

    private def self.size_u64(value : UInt64) : Int32
      return 1 if value == 0
      (70 - value.leading_zeros_count) // 7
    end

    # Encodes *value* at the start of *bytes* and returns the number of bytes
    # written. Bytes after the encoding are left untouched.
    #
    # Raises `IndexError` if *bytes* is too small to hold the encoding; nothing
    # is written in that case.
    def self.encode(value : Int::Unsigned, bytes : Bytes) : Int32
      encode_u64(value.to_u64, bytes)
    end

    # :ditto:
    def self.encode(value : Int::Signed, bytes : Bytes) : Int32
      encode_u64(value.to_i64.to_u64!, bytes)
    end

    private def self.encode_u64(value : UInt64, bytes : Bytes) : Int32
      if value < 0x80
        raise IndexError.new("Varint needs 1 byte but the buffer is empty") if bytes.empty?
        bytes.to_unsafe[0] = value.to_u8!
        return 1
      end

      size = size_u64(value)
      if bytes.size < size
        raise IndexError.new("Varint needs #{size} bytes but the buffer has #{bytes.size}")
      end

      ptr = bytes.to_unsafe
      i = 0
      while value >= 0x80
        ptr[i] = value.to_u8! | 0x80
        value >>= 7
        i += 1
      end
      ptr[i] = value.to_u8!
      size
    end

    # Encodes *value* into *io* with a single write and returns the number of
    # bytes written.
    def self.encode(value : Int, io : IO) : Int32
      if 0 <= value < 0x80
        io.write_byte(value.to_u8!)
        return 1
      end

      buffer = uninitialized UInt8[MAX_SIZE]
      size = encode(value, buffer.to_slice)
      io.write(buffer.to_slice[0, size])
      size
    end

    # Decodes a *type* from the start of *bytes* and returns the value together
    # with the number of bytes consumed. Bytes after the encoding are ignored.
    #
    # Raises `Error` if the encoding is truncated or malformed, or if the value
    # does not fit *type*. See `.decode?` to detect truncation without raising.
    def self.decode(type : T.class, bytes : Bytes, *, strict : Bool = false) : {T, Int32} forall T
      raw, size = decode_u64(bytes, strict) { raise_truncated }
      {convert(type, raw), size}
    end

    # Like `.decode` but returns `nil` if *bytes* ends before the encoding
    # does, so a caller filling a buffer can tell "need more data" from
    # "malformed", which still raises `Error`.
    def self.decode?(type : T.class, bytes : Bytes, *, strict : Bool = false) : {T, Int32}? forall T
      raw, size = decode_u64(bytes, strict) { return nil }
      {convert(type, raw), size}
    end

    # Decodes a *type* from *io*.
    #
    # Raises `IO::EOFError` if *io* ends before the encoding does and `Error`
    # if the encoding is malformed or the value does not fit *type*.
    def self.decode(type : T.class, io : IO, *, strict : Bool = false) : T forall T
      convert(type, decode_u64(io, strict))
    end

    # Encodes the zigzag mapping of *value* (see `Zigzag`) at the start of
    # *bytes* and returns the number of bytes written.
    def self.encode_zigzag(value : Int::Signed, bytes : Bytes) : Int32
      encode(Zigzag.encode(value), bytes)
    end

    # Encodes the zigzag mapping of *value* (see `Zigzag`) into *io* and
    # returns the number of bytes written.
    def self.encode_zigzag(value : Int::Signed, io : IO) : Int32
      encode(Zigzag.encode(value), io)
    end

    # Decodes a zigzag-encoded (see `Zigzag`) signed *type* from the start of
    # *bytes* and returns the value with the number of bytes consumed.
    #
    # Raises `Error` like `.decode`.
    def self.decode_zigzag(type : T.class, bytes : Bytes, *, strict : Bool = false) : {T, Int32} forall T
      raw, size = decode_u64(bytes, strict) { raise_truncated }
      {convert_signed(type, Zigzag.decode(raw)), size}
    end

    # Decodes a zigzag-encoded (see `Zigzag`) signed *type* from *io*.
    #
    # Raises `IO::EOFError` and `Error` like `.decode`.
    def self.decode_zigzag(type : T.class, io : IO, *, strict : Bool = false) : T forall T
      convert_signed(type, Zigzag.decode(decode_u64(io, strict)))
    end

    # Yields when *bytes* ends before the encoding does; the block must not
    # return normally (it raises or returns from the caller).
    private def self.decode_u64(bytes : Bytes, strict : Bool, &) : {UInt64, Int32}
      size = bytes.size
      yield if size == 0

      ptr = bytes.to_unsafe
      byte = ptr[0]
      return {byte.to_u64, 1} if byte < 0x80

      value = (byte & 0x7f).to_u64
      shift = 7
      i = 1
      while i < MAX_SIZE
        yield if i >= size
        byte = ptr[i]
        i += 1
        raise_overflow if i == MAX_SIZE && byte > 0x01
        value |= (byte & 0x7f).to_u64 << shift
        if byte < 0x80
          raise_not_canonical if strict && byte == 0
          return {value, i}
        end
        shift += 7
      end
      raise_overflow
    end

    private def self.decode_u64(io : IO, strict : Bool) : UInt64
      # Fast path: decode straight from the IO's read buffer when it holds a
      # whole encoding, then skip past it. A buffer holding only a prefix
      # falls through to the byte loop, which consumes that prefix first.
      if (peek = io.peek) && !peek.empty?
        if result = decode_u64(peek, strict) { break }
          value, size = result
          io.skip(size)
          return value
        end
      end

      first = io.read_byte || raise IO::EOFError.new
      decode_u64_after(first, io, strict)
    end

    # :nodoc:
    #
    # Decodes the rest of an encoding whose first byte has already been read.
    def self.decode_u64_after(first : UInt8, io : IO, strict : Bool) : UInt64
      value = (first & 0x7f).to_u64
      return value if first < 0x80

      shift = 7
      i = 1
      while i < MAX_SIZE
        byte = io.read_byte || raise IO::EOFError.new
        i += 1
        raise_overflow if i == MAX_SIZE && byte > 0x01
        value |= (byte & 0x7f).to_u64 << shift
        if byte < 0x80
          raise_not_canonical if strict && byte == 0
          return value
        end
        shift += 7
      end
      raise_overflow
    end

    private def self.raise_truncated : NoReturn
      raise Error.new("Truncated varint")
    end

    private def self.raise_overflow : NoReturn
      raise Error.new("Varint overflows 64 bits")
    end

    private def self.raise_not_canonical : NoReturn
      raise Error.new("Varint is not canonical (trailing zero byte)")
    end

    private def self.convert(type : T.class, raw : UInt64) : T forall T
      {% if T == UInt64 %}
        raw
      {% elsif T < Int::Unsigned %}
        raise Error.new("Varint #{raw} does not fit #{T}") if raw > T::MAX
        T.new!(raw)
      {% else %}
        convert_signed(type, raw.to_i64!)
      {% end %}
    end

    private def self.convert_signed(type : T.class, value : Int64) : T forall T
      {% if T == Int64 %}
        value
      {% elsif T < Int::Signed %}
        raise Error.new("Varint #{value} does not fit #{T}") if value < T::MIN || value > T::MAX
        T.new!(value)
      {% else %}
        {% raise "Binary::Varint: expected a signed integer type, not #{T}" %}
      {% end %}
    end
  end

  # The zigzag mapping between signed and unsigned integers of the same width:
  # `0, -1, 1, -2, 2, ...` map to `0, 1, 2, 3, 4, ...`, so values close to zero
  # in either direction get short `Varint` encodings.
  #
  # ```
  # Binary::Zigzag.encode(-1_i32)         # => 1_u32
  # Binary::Zigzag.encode(Int32::MIN)     # => 4294967295_u32
  # Binary::Zigzag.decode(4294967295_u32) # => Int32::MIN
  # ```
  module Zigzag
    {% for signed, unsigned in {Int8 => UInt8, Int16 => UInt16, Int32 => UInt32, Int64 => UInt64, Int128 => UInt128} %}
      # Maps a signed *value* to an unsigned integer of the same width.
      def self.encode(value : {{signed}}) : {{unsigned}}
        ((value << 1) ^ (value >> sizeof({{signed}}) * 8 - 1)).unsafe_as({{unsigned}})
      end

      # Maps an unsigned *value* back to the signed integer it was encoded from.
      def self.decode(value : {{unsigned}}) : {{signed}}
        (value >> 1).unsafe_as({{signed}}) ^ -(value & 1).unsafe_as({{signed}})
      end
    {% end %}
  end
end

class IO
  # Writes *value* as a `Binary::Varint` and returns the number of bytes
  # written.
  #
  # ```
  # io = IO::Memory.new
  # io.write_varint(300) # => 2
  # io.to_slice          # => Bytes[0xac, 0x02]
  # ```
  def write_varint(value : Int) : Int32
    Binary::Varint.encode(value, self)
  end

  # Reads a `Binary::Varint` of the given *type* (`UInt64` by default).
  #
  # Raises `IO::EOFError` if this IO ends first and `Binary::Varint::Error`
  # if the encoding is malformed or does not fit *type*.
  #
  # ```
  # io = IO::Memory.new(Bytes[0xac, 0x02])
  # io.read_varint(UInt32) # => 300
  # ```
  def read_varint(type : T.class, *, strict : Bool = false) : T forall T
    Binary::Varint.decode(type, self, strict: strict)
  end

  # :ditto:
  def read_varint(*, strict : Bool = false) : UInt64
    Binary::Varint.decode(UInt64, self, strict: strict)
  end

  # Writes *value* as a zigzag `Binary::Varint` (see `Binary::Zigzag`) and
  # returns the number of bytes written.
  #
  # ```
  # io = IO::Memory.new
  # io.write_zigzag(-1) # => 1
  # io.to_slice         # => Bytes[0x01]
  # ```
  def write_zigzag(value : Int::Signed) : Int32
    Binary::Varint.encode_zigzag(value, self)
  end

  # Reads a zigzag `Binary::Varint` (see `Binary::Zigzag`) of the given signed
  # *type* (`Int64` by default).
  #
  # Raises `IO::EOFError` and `Binary::Varint::Error` like `#read_varint`.
  #
  # ```
  # io = IO::Memory.new(Bytes[0x01])
  # io.read_zigzag(Int32) # => -1
  # ```
  def read_zigzag(type : T.class, *, strict : Bool = false) : T forall T
    Binary::Varint.decode_zigzag(type, self, strict: strict)
  end

  # :ditto:
  def read_zigzag(*, strict : Bool = false) : Int64
    Binary::Varint.decode_zigzag(Int64, self, strict: strict)
  end
end
