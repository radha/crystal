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
    @staged : StaticArray(UInt8, 8) = StaticArray(UInt8, 8).new(0_u8)
    @staged_count : Int32 = 0
    @staged_pos : Int32 = 0

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
      n = n.to_i32
      if n <= @bits
        return take(n)
      end
      have = @bits
      rest = n - have
      # Peek availability before consuming anything, so a short read leaves the reader untouched.
      return nil unless available?(rest)
      first = have > 0 ? take(have) : 0_u64
      fill(rest)
      second = take(rest)
      if @order.msb?
        (first << rest) | second
      else
        first | (second << have)
      end
    end

    # Returns true if at least *n* more bits are available to read without consuming.
    # For IO-backed readers, stages bytes into a buffer without consuming them logically.
    private def available?(n : Int32) : Bool
      if bytes = @bytes
        (bytes.size - @pos) * 8 >= n
      else
        io = @io.not_nil!
        needed = (n + 7) // 8
        if @staged_pos > 0
          remaining = @staged_count - @staged_pos
          (@staged.to_slice + @staged_pos).copy_to(@staged.to_unsafe, remaining) if remaining > 0
          @staged_count = remaining
          @staged_pos = 0
        end
        staged_remaining = @staged_count - @staged_pos
        while staged_remaining < needed
          byte = io.read_byte
          if byte.nil?
            return false
          end
          @staged[@staged_count] = byte
          @staged_count += 1
          staged_remaining += 1
        end
        true
      end
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
        !available?(1)
      end
    end

    # Ensures at least *n* bits are buffered. Raises `IO::EOFError` at end of data.
    # The accumulator never holds more than 64 bits: refills happen only while
    # `@bits < n <= 64`, adding 8 bits (or 64 when empty) each time.
    private def fill(n : Int32) : Nil
      while @bits < n
        if @bits == 0 && (bytes = @bytes) && bytes.size - @pos >= 8
          word = Slice.new(bytes.to_unsafe + @pos, 8)
          @acc = @order.msb? ? IO::ByteFormat::BigEndian.decode(UInt64, word) : IO::ByteFormat::LittleEndian.decode(UInt64, word)
          @pos += 8
          @bits = 64
          next
        end
        byte = next_byte
        raise IO::EOFError.new unless byte
        if @order.msb?
          @acc = (@acc << 8) | byte
        else
          @acc |= byte.to_u64 << @bits
        end
        @bits += 8
      end
    end

    private def next_byte : UInt8?
      if bytes = @bytes
        return nil if @pos >= bytes.size
        b = bytes.to_unsafe[@pos]
        @pos += 1
        b
      elsif @staged_pos < @staged_count
        b = @staged[@staged_pos]
        @staged_pos += 1
        if @staged_pos == @staged_count
          @staged_pos = 0
          @staged_count = 0
        end
        b
      else
        @io.not_nil!.read_byte
      end
    end

    # Removes *n* (<= @bits) bits from the accumulator and returns them.
    private def take(n : Int32) : UInt64
      mask = n == 64 ? UInt64::MAX : (1_u64 << n) - 1
      if @order.msb?
        @bits -= n
        value = (@acc >> @bits) & mask
        @acc &= (@bits == 64 ? UInt64::MAX : (1_u64 << @bits) - 1)
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
          part = (value >> (remaining - chunk)) & (chunk == 64 ? UInt64::MAX : (1_u64 << chunk) - 1)
          @acc = (chunk == 64 ? 0_u64 : @acc << chunk) | part
        else
          part = value & (chunk == 64 ? UInt64::MAX : (1_u64 << chunk) - 1)
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
          @acc &= (@bits == 0 ? 0_u64 : (1_u64 << @bits) - 1)
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
