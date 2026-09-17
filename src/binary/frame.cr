module Binary
  # Length-prefixed frames over any `IO`.
  #
  # A frame is a length prefix followed by that many bytes of body. The
  # prefix is a big-endian `UInt32` by default; see `Prefix` for the other
  # kinds. The length never includes the prefix itself.
  #
  # ```
  # require "binary"
  #
  # io = IO::Memory.new
  # io.write_frame("ping".to_slice)
  # io.write_frame(prefix: :varint) { |body| body << "pong" }
  # io.to_slice # => Bytes[0, 0, 0, 4, 112, 105, 110, 103, 4, 112, 111, 110, 103]
  #
  # io.rewind
  # io.read_frame                  # => Bytes[112, 105, 110, 103]
  # io.read_frame(prefix: :varint) # => Bytes[112, 111, 110, 103]
  # io.read_frame?                 # => nil
  # ```
  #
  # Reading checks the length against *max_size* (`DEFAULT_MAX_SIZE`, 16 MiB)
  # before allocating anything and raises `TooLargeError` if it is exceeded,
  # so a hostile peer cannot make the reader allocate an arbitrary buffer.
  # A stream that ends inside a frame raises `IO::EOFError`; `.read?`
  # returns `nil` only when the stream ends exactly at a frame boundary.
  module Frame
    # Raised when a frame's length exceeds the *max_size* given to the reader.
    class TooLargeError < Binary::Error
      # The length the prefix announced.
      getter size : UInt64

      # The limit it exceeded.
      getter max_size : Int32

      def initialize(@size : UInt64, @max_size : Int32)
        super("Frame of #{@size} bytes exceeds the maximum of #{@max_size}")
      end
    end

    # The default upper bound on a frame's length: 16 MiB.
    DEFAULT_MAX_SIZE = 16 * 1024 * 1024

    # Bodies up to this size are copied next to their prefix and written with a
    # single `IO#write`, which is one syscall on an unbuffered socket.
    private INLINE_LIMIT = 4096

    # `INLINE_LIMIT` plus the longest prefix.
    private INLINE_BUFFER_SIZE = 4106

    # How a frame's length is encoded.
    enum Prefix
      # Four bytes, most significant first.
      U32BE
      # Four bytes, least significant first.
      U32LE
      # Two bytes, most significant first.
      U16BE
      # Two bytes, least significant first.
      U16LE
      # A `Binary::Varint`.
      Varint
    end

    # Writes *body* as one frame: its length as *prefix*, then its bytes.
    #
    # Raises `ArgumentError` if the length does not fit *prefix*.
    def self.write(io : IO, body : Bytes, *, prefix : Prefix = :u32_be) : Nil
      if body.size <= INLINE_LIMIT
        buffer = uninitialized UInt8[INLINE_BUFFER_SIZE]
        size = encode_prefix(body.size, buffer.to_slice, prefix)
        body.copy_to(buffer.to_unsafe + size, body.size)
        io.write(buffer.to_slice[0, size + body.size])
      else
        write_prefix(body.size, io, prefix: prefix)
        io.write(body)
      end
    end

    # Yields an `IO` to build the body in, then writes it as one frame.
    #
    # ```
    # Binary::Frame.write(io) do |body|
    #   body.write_bytes(42_u16, IO::ByteFormat::BigEndian)
    #   body << "name"
    # end
    # ```
    def self.write(io : IO, *, prefix : Prefix = :u32_be, & : IO ->) : Nil
      body = IO::Memory.new
      yield body
      write(io, body.to_slice, prefix: prefix)
    end

    # Reads one frame and returns its body in a new `Bytes` of exactly the
    # frame's length.
    #
    # Raises `IO::EOFError` if *io* ends before the frame does (including at
    # the very start; see `.read?`), `TooLargeError` if the length exceeds
    # *max_size*, and `Binary::Varint::Error` for a malformed varint prefix.
    def self.read(io : IO, *, prefix : Prefix = :u32_be, max_size : Int32 = DEFAULT_MAX_SIZE) : Bytes
      read?(io, prefix: prefix, max_size: max_size) || raise IO::EOFError.new
    end

    # Like `.read`, but returns `nil` if *io* has ended exactly at a frame
    # boundary, so a loop can consume frames until the peer closes.
    # A stream that ends inside a prefix or body still raises `IO::EOFError`.
    def self.read?(io : IO, *, prefix : Prefix = :u32_be, max_size : Int32 = DEFAULT_MAX_SIZE) : Bytes?
      length = read_prefix?(io, prefix, max_size) || return nil
      return Bytes.empty if length == 0

      body = Bytes.new(Pointer(UInt8).malloc_uninitialized(length), length)
      io.read_fully(body)
      body
    end

    # Reads one frame into *into*, replacing its previous content, and returns
    # the frame's length. *into* is rewound so the body can be read from it
    # right away. Reusing one `IO::Memory` avoids an allocation per frame.
    #
    # Raises like `.read`.
    def self.read(io : IO, *, into : IO::Memory, prefix : Prefix = :u32_be, max_size : Int32 = DEFAULT_MAX_SIZE) : Int32
      length = read_prefix(io, prefix: prefix, max_size: max_size)
      into.clear
      if length > 0
        if (peek = io.peek) && peek.size >= length
          into.write(peek[0, length])
          io.skip(length)
        elsif IO.copy(io, into, length) < length
          raise IO::EOFError.new
        end
      end
      into.rewind
      length
    end

    # Writes just a length prefix for a frame of *length* bytes and returns
    # the number of bytes written. Useful when the body is written separately.
    #
    # Raises `ArgumentError` if *length* is negative or does not fit *prefix*.
    def self.write_prefix(length : Int, io : IO, *, prefix : Prefix = :u32_be) : Int32
      buffer = uninitialized UInt8[Varint::MAX_SIZE]
      size = encode_prefix(length, buffer.to_slice, prefix)
      io.write(buffer.to_slice[0, size])
      size
    end

    # Reads just a length prefix and returns the length it announces.
    #
    # Raises `IO::EOFError` if *io* ends first, `TooLargeError` if the length
    # exceeds *max_size*.
    def self.read_prefix(io : IO, *, prefix : Prefix = :u32_be, max_size : Int32 = DEFAULT_MAX_SIZE) : Int32
      read_prefix?(io, prefix, max_size) || raise IO::EOFError.new
    end

    private def self.encode_prefix(length : Int, bytes : Bytes, prefix : Prefix) : Int32
      raise ArgumentError.new("Negative frame length: #{length}") if length < 0

      case prefix
      in .u32_be? then encode_fixed(length, bytes, UInt32, IO::ByteFormat::BigEndian)
      in .u32_le? then encode_fixed(length, bytes, UInt32, IO::ByteFormat::LittleEndian)
      in .u16_be? then encode_fixed(length, bytes, UInt16, IO::ByteFormat::BigEndian)
      in .u16_le? then encode_fixed(length, bytes, UInt16, IO::ByteFormat::LittleEndian)
      in .varint? then Varint.encode(length.to_u64, bytes)
      end
    end

    private def self.encode_fixed(length : Int, bytes : Bytes, type : T.class, format : IO::ByteFormat) : Int32 forall T
      if length > T::MAX
        raise ArgumentError.new("Frame of #{length} bytes does not fit a #{T} prefix")
      end
      format.encode(T.new!(length), bytes)
      sizeof(T)
    end

    # Returns `nil` only when *io* is at EOF before the first prefix byte.
    private def self.read_prefix?(io : IO, prefix : Prefix, max_size : Int32) : Int32?
      length =
        case prefix
        in .u32_be? then read_fixed?(io, UInt32, IO::ByteFormat::BigEndian)
        in .u32_le? then read_fixed?(io, UInt32, IO::ByteFormat::LittleEndian)
        in .u16_be? then read_fixed?(io, UInt16, IO::ByteFormat::BigEndian)
        in .u16_le? then read_fixed?(io, UInt16, IO::ByteFormat::LittleEndian)
        in .varint? then read_varint?(io)
        end
      return nil unless length

      raise TooLargeError.new(length, max_size) if length > max_size
      length.to_i32!
    end

    private def self.read_fixed?(io : IO, type : T.class, format : IO::ByteFormat) : UInt64? forall T
      if (peek = io.peek) && peek.size >= sizeof(T)
        value = format.decode(T, peek)
        io.skip(sizeof(T))
        return value.to_u64
      end

      buffer = uninitialized UInt8[sizeof(T)]
      count = io.read_greedy(buffer.to_slice)
      return nil if count == 0
      raise IO::EOFError.new if count < sizeof(T)
      format.decode(T, buffer.to_slice).to_u64
    end

    private def self.read_varint?(io : IO) : UInt64?
      if peek = io.peek
        return nil if peek.empty?
        Varint.decode(UInt64, io)
      else
        first = io.read_byte || return nil
        Varint.decode_u64_after(first, io, false)
      end
    end
  end
end

class IO
  # Writes *body* as a `Binary::Frame`: its length as *prefix*, then its bytes.
  #
  # ```
  # io = IO::Memory.new
  # io.write_frame("abc".to_slice)
  # io.to_slice # => Bytes[0, 0, 0, 3, 97, 98, 99]
  # ```
  def write_frame(body : Bytes, *, prefix : Binary::Frame::Prefix = :u32_be) : Nil
    Binary::Frame.write(self, body, prefix: prefix)
  end

  # Yields an `IO` to build a body in, then writes it as a `Binary::Frame`.
  #
  # ```
  # io = IO::Memory.new
  # io.write_frame { |body| body << "abc" }
  # io.to_slice # => Bytes[0, 0, 0, 3, 97, 98, 99]
  # ```
  def write_frame(*, prefix : Binary::Frame::Prefix = :u32_be, & : IO ->) : Nil
    Binary::Frame.write(self, prefix: prefix) { |body| yield body }
  end

  # Reads one `Binary::Frame` and returns its body.
  #
  # Raises `IO::EOFError` if this IO ends before the frame does and
  # `Binary::Frame::TooLargeError` if the length exceeds *max_size*.
  #
  # ```
  # io = IO::Memory.new(Bytes[0, 0, 0, 3, 97, 98, 99])
  # io.read_frame # => Bytes[97, 98, 99]
  # ```
  def read_frame(*, prefix : Binary::Frame::Prefix = :u32_be, max_size : Int32 = Binary::Frame::DEFAULT_MAX_SIZE) : Bytes
    Binary::Frame.read(self, prefix: prefix, max_size: max_size)
  end

  # Like `#read_frame`, but returns `nil` if this IO has ended at a frame
  # boundary.
  #
  # ```
  # while body = socket.read_frame?
  #   handle(body)
  # end
  # ```
  def read_frame?(*, prefix : Binary::Frame::Prefix = :u32_be, max_size : Int32 = Binary::Frame::DEFAULT_MAX_SIZE) : Bytes?
    Binary::Frame.read?(self, prefix: prefix, max_size: max_size)
  end

  # Reads one `Binary::Frame` into *into*, replacing its content, and returns
  # the frame's length. See `Binary::Frame.read(io, into:)`.
  def read_frame(*, into : IO::Memory, prefix : Binary::Frame::Prefix = :u32_be, max_size : Int32 = Binary::Frame::DEFAULT_MAX_SIZE) : Int32
    Binary::Frame.read(self, into: into, prefix: prefix, max_size: max_size)
  end
end
