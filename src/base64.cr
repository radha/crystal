# The `Base64` module provides for the encoding (`encode`, `strict_encode`,
# `urlsafe_encode`) and decoding (`decode`)
# of binary data using a base64 representation.
#
# ### Example
#
# A simple encoding and decoding.
#
# ```
# require "base64"
#
# enc = Base64.encode("Send reinforcements") # => "U2VuZCByZWluZm9yY2VtZW50cw==\n"
# plain = Base64.decode_string(enc)          # => "Send reinforcements"
# ```
#
# The purpose of using base64 to encode data is that it translates any binary
# data into purely printable characters.
module Base64
  extend self

  class Error < Exception; end

  private CHARS_STD  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  private CHARS_SAFE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  private LINE_SIZE  = 60
  private PAD        = '='.ord.to_u8
  private NL         = '\n'.ord.to_u8
  private NR         = '\r'.ord.to_u8

  # Returns the base64-encoded version of *data*.
  # This method complies with [RFC 2045](https://tools.ietf.org/html/rfc2045).
  # Line feeds are added to every 60 encoded characters.
  #
  # ```
  # puts Base64.encode("Now is the time for all good coders\nto learn Crystal")
  # ```
  #
  # Generates:
  #
  # ```text
  # Tm93IGlzIHRoZSB0aW1lIGZvciBhbGwgZ29vZCBjb2RlcnMKdG8gbGVhcm4g
  # Q3J5c3RhbA==
  # ```
  def encode(data) : String
    slice = data.to_slice
    String.new(encode_size(slice.size, new_lines: true)) do |buf|
      size = encode_lines_raw(slice, buf)
      {size, size}
    end
  end

  # Writes the base64-encoded version of *data* to *io*.
  # This method complies with [RFC 2045](https://tools.ietf.org/html/rfc2045).
  # Line feeds are added to every 60 encoded characters.
  #
  # ```
  # Base64.encode("Now is the time for all good coders\nto learn Crystal", STDOUT)
  # ```
  def encode(data, io : IO)
    encode_to_io(data.to_slice, io) { |chunk, dst| encode_lines_raw(chunk, dst) }
  end

  # Returns the base64-encoded version of *data* with no newlines.
  # This method complies with [RFC 4648](https://tools.ietf.org/html/rfc4648).
  #
  # ```
  # puts Base64.strict_encode("Now is the time for all good coders\nto learn Crystal")
  # ```
  #
  # Generates:
  #
  # ```text
  # Tm93IGlzIHRoZSB0aW1lIGZvciBhbGwgZ29vZCBjb2RlcnMKdG8gbGVhcm4gQ3J5c3RhbA==
  # ```
  def strict_encode(data) : String
    strict_encode data, ENCODE_TABLE_STD, pad: true
  end

  private def strict_encode(data, table, pad = false)
    slice = data.to_slice
    String.new(encode_size(slice.size)) do |buf|
      size = encode_raw(slice, buf, table, pad)
      {size, size}
    end
  end

  # Writes the base64-encoded version of *data* with no newlines to *io*.
  # This method complies with [RFC 4648](https://tools.ietf.org/html/rfc4648).
  #
  # ```
  # Base64.strict_encode("Now is the time for all good coders\nto learn Crystal", STDOUT)
  # ```
  def strict_encode(data, io : IO)
    strict_encode_to_io_internal(data, io, ENCODE_TABLE_STD, pad: true)
  end

  private def strict_encode_to_io_internal(data, io, table, pad)
    encode_to_io(data.to_slice, io) { |chunk, dst| encode_raw(chunk, dst, table, pad) }
  end

  # Returns the base64-encoded version of *data* using a urlsafe alphabet.
  # This method complies with "Base 64 Encoding with URL and Filename Safe
  # Alphabet" in [RFC 4648](https://tools.ietf.org/html/rfc4648).
  #
  # The alphabet uses `'-'` instead of `'+'` and `'_'` instead of `'/'`.
  #
  # The *padding* parameter defaults to `true`. When `false`, enough `=` characters
  # are not added to make the output divisible by 4.
  def urlsafe_encode(data, padding = true) : String
    strict_encode data, ENCODE_TABLE_SAFE, pad: padding
  end

  # Writes the base64-encoded version of *data* using a urlsafe alphabet to *io*.
  # This method complies with "Base 64 Encoding with URL and Filename Safe
  # Alphabet" in [RFC 4648](https://tools.ietf.org/html/rfc4648).
  #
  # The alphabet uses `'-'` instead of `'+'` and `'_'` instead of `'/'`.
  def urlsafe_encode(data, io : IO)
    strict_encode_to_io_internal(data, io, ENCODE_TABLE_SAFE, pad: true)
  end

  # Returns the base64-decoded version of *data* as a `Bytes`.
  # This will decode either the normal or urlsafe alphabets.
  def decode(data) : Bytes
    slice = data.to_slice
    capacity = decode_size(slice.size)
    buf = Pointer(UInt8).malloc(capacity)
    Slice.new(buf, decode_into(slice, buf, capacity))
  end

  # Writes the base64-decoded version of *data* to *io*.
  # This will decode either the normal or urlsafe alphabets.
  def decode(data, io : IO)
    buffer = uninitialized UInt8[IO_CHUNK_DECODED]
    dst = buffer.to_unsafe
    count = 0
    size = from_base64(data.to_slice, dst, IO_CHUNK_DECODED) do |chunk_size|
      io.write(Slice.new(dst, chunk_size))
      count += chunk_size
    end
    if size > 0
      io.write(Slice.new(dst, size))
      count += size
    end
    io.flush
    count
  end

  # Returns the base64-decoded version of *data* as a string.
  # This will decode either the normal or urlsafe alphabets.
  def decode_string(data) : String
    slice = data.to_slice
    capacity = decode_size(slice.size)
    String.new(capacity) do |buf|
      {decode_into(slice, buf, capacity), 0}
    end
  end

  # Decodes all of *data* into *dst*, which must hold *capacity* bytes,
  # where *capacity* is `decode_size(data.size)`. Returns the number of
  # bytes written.
  private def decode_into(data : Bytes, dst : UInt8*, capacity : Int32) : Int32
    # That capacity always holds the whole output, so `from_base64` never
    # needs to hand over a filled buffer.
    from_base64(data, dst, capacity) { }
  end

  private def encode_size(str_size, new_lines = false)
    size = (str_size * 4 / 3.0).to_i + 4
    size += size // LINE_SIZE if new_lines
    size
  end

  private def decode_size(str_size)
    (str_size * 3 / 4.0).to_i + 4
  end

  # Every 12 bits of input map to a pair of output characters, stored in
  # memory order (first character in the low byte).
  private ENCODE_TABLE_STD = Slice(UInt16).new(4096, read_only: true) do |i|
    CHARS_STD.to_unsafe[i >> 6].to_u16 | (CHARS_STD.to_unsafe[i & 63].to_u16 << 8)
  end
  private ENCODE_TABLE_SAFE = Slice(UInt16).new(4096, read_only: true) do |i|
    CHARS_SAFE.to_unsafe[i >> 6].to_u16 | (CHARS_SAFE.to_unsafe[i & 63].to_u16 << 8)
  end

  # Input bytes encoded per `IO` write: a multiple of 45 so that every chunk
  # ends exactly at a line break (and at a full triple).
  private IO_CHUNK_INPUT = 45 * 64
  # Largest possible output for `IO_CHUNK_INPUT` bytes: 64 lines of 60
  # characters plus a line feed each.
  private IO_CHUNK_ENCODED = 61 * 64
  # Decoded bytes buffered per `IO` write (a multiple of 3).
  private IO_CHUNK_DECODED = 3 * 1024

  # Encodes *data* in chunks into a stack buffer and writes each chunk to *io*
  # as text. Returns the number of characters written.
  private def encode_to_io(data : Bytes, io : IO, &) : Int32
    buffer = uninitialized UInt8[IO_CHUNK_ENCODED]
    dst = buffer.to_unsafe
    count = 0
    while data.size > 0
      chunk = data[0, Math.min(data.size, IO_CHUNK_INPUT)]
      size = yield chunk, dst
      io.write_string(Slice.new(dst, size))
      count += size
      data += chunk.size
    end
    io.flush
    count
  end

  # Encodes *data* into *dst* with line feeds after every 60 characters and
  # after the last one. Returns the number of bytes written.
  private def encode_lines_raw(data : Bytes, dst : UInt8*) : Int32
    table = ENCODE_TABLE_STD.to_unsafe
    src = data.to_unsafe
    size = data.size
    start = dst

    # Full lines: 45 input bytes give 60 characters. The 4-byte load of the
    # last triple of a line reads one byte into the next line, so the last
    # (possibly full) line goes through `encode_raw`, which never reads past
    # the end.
    while size > 45
      {% for i in 0...15 %}
        dst = encode_triple(src, dst, table)
        src += 3
      {% end %}
      dst.value = NL
      dst += 1
      size -= 45
    end

    if size > 0
      dst += encode_raw(Slice.new(src, size), dst, ENCODE_TABLE_STD, pad: true)
      dst.value = NL
      dst += 1
    end

    (dst - start).to_i32
  end

  # Encodes the triple at *src* into four characters at *dst*, loading four
  # bytes at once. Returns the advanced *dst*.
  @[AlwaysInline]
  private def encode_triple(src : UInt8*, dst : UInt8*, table : UInt16*) : UInt8*
    n = src.as(UInt32*).value.byte_swap
    dst.as(UInt32*).value = table[n >> 20].to_u32 | (table[(n >> 8) & 0xFFF].to_u32 << 16)
    dst + 4
  end

  # Encodes *data* into *dst* without line feeds, padding the last group
  # with `=` if *pad*. Returns the number of bytes written.
  private def encode_raw(data : Bytes, dst : UInt8*, table : Slice(UInt16), pad : Bool) : Int32
    size = data.size
    src = data.to_unsafe
    start = dst
    return 0 if src.null? || size == 0
    table = table.to_unsafe

    full = size // 3
    if full > 0
      # All full triples but the last one: reading 4 bytes stays in bounds
      stop = src + (full - 1) * 3
      while src < stop
        dst = encode_triple(src, dst, table)
        src += 3
      end

      # The last full triple, without reading past the end
      n = (src[0].to_u32 << 16) | (src[1].to_u32 << 8) | src[2]
      dst.as(UInt32*).value = table[n >> 12].to_u32 | (table[n & 0xFFF].to_u32 << 16)
      dst += 4
      src += 3
    end

    case size - full * 3
    when 1
      n = src[0].to_u32 << 4
      dst.as(UInt16*).value = table[n]
      dst += 2
      if pad
        dst[0] = PAD
        dst[1] = PAD
        dst += 2
      end
    when 2
      n = (src[0].to_u32 << 10) | (src[1].to_u32 << 2)
      dst.as(UInt16*).value = table[n >> 6]
      dst[2] = table[(n & 63) << 6].to_u8! # low byte: the character for `n & 63`
      dst += 3
      if pad
        dst.value = PAD
        dst += 1
      end
    end

    (dst - start).to_i32
  end

  private INVALID = UInt32::MAX

  # Decoded value of each byte; `INVALID` for bytes outside both alphabets.
  private DECODE_TABLE = Array(UInt32).new(size: 256) do |i|
    case i.unsafe_chr
    when 'A'..'Z' then (i - 0x41).to_u32
    when 'a'..'z' then (i - 0x47).to_u32
    when '0'..'9' then (i + 0x04).to_u32
    when '+', '-' then 0x3E_u32
    when '/', '_' then 0x3F_u32
    else               INVALID
    end
  end

  # Decodes *data* into the *capacity* bytes at *dst*. Whenever the buffer
  # cannot take the next group (and before raising), the number of bytes
  # written so far is yielded and decoding restarts at *dst*. Returns the
  # number of bytes written since the last yield. *capacity* must be at
  # least 6.
  private def from_base64(data : Bytes, dst : UInt8*, capacity : Int32, &) : Int32
    size = data.size
    bytes = data.to_unsafe
    bytes_begin = bytes
    table = DECODE_TABLE.to_unsafe

    # Get the position of the last valid base64 character (rstrip '\n', '\r' and '=')
    while (size > 0) && (sym = bytes[size - 1]) && sym.in?(NL, NR, PAD)
      size -= 1
    end

    # Process combinations of four characters until there aren't any left
    fin = bytes + size - 4
    cur = dst
    # Four bytes (a decoded group plus one scratch byte) fit at *cur* iff
    # `cur <= cur_stop`
    cur_stop = dst + (capacity - 4)
    while bytes <= fin
      if cur > cur_stop
        yield (cur - dst).to_i32
        cur = dst
      end

      value = (table[bytes[0]] << 18) | (table[bytes[1]] << 12) | (table[bytes[2]] << 6) | table[bytes[3]]
      # Any `INVALID` entry sets the high bits (shifts wrap); line breaks are
      # `INVALID` too, so a group never starts with one
      if value > 0xFFFFFF
        # Move the pointer by one byte until there is a valid base64 character
        if bytes.value.in?(NL, NR)
          bytes += 1
          next
        end
        yield (cur - dst).to_i32
        raise_unexpected(bytes, bytes - bytes_begin, 4)
      end
      # The three decoded bytes in memory order, plus a scratch zero byte
      cur.as(UInt32*).value = value.byte_swap >> 8
      cur += 3
      bytes += 4
    end

    # Move the pointer by one byte until there is a valid base64 character or the end of `bytes` was reached
    while (bytes < fin + 4) && bytes.value.in?(NL, NR)
      bytes += 1
    end

    # If the amount of base64 characters is not divisible by 4, the remainder of the previous loop is handled here
    unread_bytes = (fin - bytes) % 4
    if unread_bytes > 0 && cur > cur_stop + 2
      yield (cur - dst).to_i32
      cur = dst
    end
    case unread_bytes
    when 1
      yield (cur - dst).to_i32
      raise Base64::Error.new("Wrong size")
    when 2
      value = (table[bytes[0]] << 6) | table[bytes[1]]
      if value > 0xFFF
        yield (cur - dst).to_i32
        raise_unexpected(bytes, bytes - bytes_begin, 2)
      end
      cur[0] = (value >> 4).to_u8!
      cur += 1
    when 3
      value = (table[bytes[0]] << 12) | (table[bytes[1]] << 6) | table[bytes[2]]
      if value > 0x3FFFF
        yield (cur - dst).to_i32
        raise_unexpected(bytes, bytes - bytes_begin, 3)
      end
      cur[0] = (value >> 10).to_u8!
      cur[1] = (value >> 2).to_u8!
      cur += 2
    end

    (cur - dst).to_i32
  end

  # Raises for the first invalid byte among the *count* bytes at *bytes*,
  # where *pos* is the position of *bytes* in the input.
  private def raise_unexpected(bytes : UInt8*, pos : Int64, count : Int32) : NoReturn
    table = DECODE_TABLE.to_unsafe
    count.times do |i|
      if table[bytes[i]] == INVALID
        raise Base64::Error.new("Unexpected byte 0x#{bytes[i].to_s(16)} at #{pos + i}")
      end
    end
    raise Base64::Error.new("Unexpected byte")
  end
end
