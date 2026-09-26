require "big"
require "uuid"
require "json"
require "./error"
require "./oid"
require "./interval"
require "./result"

module Postgres
  # :nodoc:
  #
  # Binary parameter encoders and column decoders (see the type tables in
  # the `Postgres` module doc). Encoders write a value's bytes, without the
  # length prefix, and return the format code they used: 1 (binary) or 0
  # (text, which lets the server parse a `String` for any type).
  module Codec
    BINARY = 1_i16
    TEXT   = 0_i16

    # Seconds from the Unix epoch to PostgreSQL's (2000-01-01 UTC).
    PG_EPOCH_UNIX = 946_684_800_i64
    PG_EPOCH_DAYS =      10_957_i64

    # --- encoding ---------------------------------------------------------

    def self.encode(io : IO, oid : UInt32, value : Bool) : Int16
      mismatch(oid, value) unless oid == OID::BOOL
      io.write_byte(value ? 1_u8 : 0_u8)
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : Int8 | Int16 | Int32 | Int64 | UInt8 | UInt16 | UInt32) : Int16
      case oid
      when OID::INT2
        io.write_bytes(checked(Int16, value, oid), IO::ByteFormat::BigEndian)
      when OID::INT4
        io.write_bytes(checked(Int32, value, oid), IO::ByteFormat::BigEndian)
      when OID::INT8
        io.write_bytes(value.to_i64, IO::ByteFormat::BigEndian)
      when OID::OID
        io.write_bytes(checked(UInt32, value, oid), IO::ByteFormat::BigEndian)
      when OID::FLOAT4
        io.write_bytes(value.to_f32, IO::ByteFormat::BigEndian)
      when OID::FLOAT8
        io.write_bytes(value.to_f64, IO::ByteFormat::BigEndian)
      when OID::NUMERIC
        write_numeric(io, BigDecimal.new(value))
      else
        mismatch(oid, value)
      end
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : Float32 | Float64) : Int16
      case oid
      when OID::FLOAT4
        io.write_bytes(value.to_f32, IO::ByteFormat::BigEndian)
      when OID::FLOAT8
        io.write_bytes(value.to_f64, IO::ByteFormat::BigEndian)
      when OID::NUMERIC
        # The text form is the shortest exact representation and covers
        # NaN and the infinities, which the server parses itself.
        io << (value.nan? ? "NaN" : value.infinite? ? (value > 0 ? "Infinity" : "-Infinity") : value.to_s)
        return TEXT
      else
        mismatch(oid, value)
      end
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : BigDecimal) : Int16
      mismatch(oid, value) unless oid == OID::NUMERIC
      write_numeric(io, value)
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : String) : Int16
      case oid
      when OID::TEXT, OID::VARCHAR, OID::BPCHAR, OID::NAME, OID::CHAR, OID::UNKNOWN, OID::JSON
        io << value
        BINARY
      when OID::JSONB
        io.write_byte(1_u8)
        io << value
        BINARY
      else
        # Any other type: send the text form and let the server parse it.
        io << value
        TEXT
      end
    end

    def self.encode(io : IO, oid : UInt32, value : Bytes) : Int16
      mismatch(oid, value) unless oid == OID::BYTEA
      io.write(value)
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : UUID) : Int16
      if oid == OID::UUID
        io.write(value.bytes.to_slice)
        BINARY
      elsif OID.text?(oid)
        io << value
        BINARY
      else
        mismatch(oid, value)
      end
    end

    def self.encode(io : IO, oid : UInt32, value : Time) : Int16
      case oid
      when OID::TIMESTAMPTZ, OID::TIMESTAMP
        io.write_bytes((value.to_unix - PG_EPOCH_UNIX) * 1_000_000 + value.nanosecond // 1000, IO::ByteFormat::BigEndian)
      when OID::DATE
        days = value.to_unix // 86_400 - PG_EPOCH_DAYS
        io.write_bytes(checked(Int32, days, oid), IO::ByteFormat::BigEndian)
      else
        mismatch(oid, value)
      end
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : Time::Span) : Int16
      case oid
      when OID::INTERVAL
        write_interval(io, Interval.new(value))
      when OID::TIME
        unless Time::Span.zero <= value < 1.day
          raise EncodeError.new("#{value} is outside a time of day (0 to 24 hours)")
        end
        io.write_bytes(value.total_nanoseconds.to_i64 // 1000, IO::ByteFormat::BigEndian)
      else
        mismatch(oid, value)
      end
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : Interval) : Int16
      mismatch(oid, value) unless oid == OID::INTERVAL
      write_interval(io, value)
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : JSON::Any) : Int16
      case oid
      when OID::JSON, OID::TEXT, OID::VARCHAR
        value.to_json(io)
      when OID::JSONB
        io.write_byte(1_u8)
        value.to_json(io)
      else
        mismatch(oid, value)
      end
      BINARY
    end

    # A one-dimensional array for array type *oid*: binary when every
    # element encodes in binary for the element type, otherwise (strings
    # for a type without a binary encoder, e.g. `inet[]`) the text literal
    # `{"a","b",NULL}` for the server to parse.
    def self.encode(io : IO, oid : UInt32, value : Array) : Int16
      element = OID.element(oid)
      unless element
        # A type the codec does not know (`inet[]`, an enum array): let the
        # server parse the text form. A known scalar type is a mistake.
        mismatch(oid, value) if OID.binary?(oid)
        return encode_array_text(io, value)
      end
      body = IO::Memory.new
      has_null = false
      value.each do |item|
        if item.nil?
          has_null = true
          body.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
        else
          length_at = body.pos
          body.write_bytes(0_i32, IO::ByteFormat::BigEndian)
          return encode_array_text(io, value) unless encode(body, element, item) == BINARY
          IO::ByteFormat::BigEndian.encode((body.pos - length_at - 4).to_i32, body.to_slice + length_at)
        end
      end
      io.write_bytes(value.empty? ? 0_i32 : 1_i32, IO::ByteFormat::BigEndian)
      io.write_bytes(has_null ? 1_i32 : 0_i32, IO::ByteFormat::BigEndian)
      io.write_bytes(element, IO::ByteFormat::BigEndian)
      unless value.empty?
        io.write_bytes(value.size.to_i32, IO::ByteFormat::BigEndian)
        io.write_bytes(1_i32, IO::ByteFormat::BigEndian) # lower bound
      end
      io.write(body.to_slice)
      BINARY
    end

    private def self.encode_array_text(io : IO, value : Array) : Int16
      io << '{'
      value.each_with_index do |item, i|
        io << ',' if i > 0
        if item.nil?
          io << "NULL"
        else
          io << '"'
          item.to_s.each_char do |char|
            io << '\\' if char == '"' || char == '\\'
            io << char
          end
          io << '"'
        end
      end
      io << '}'
      TEXT
    end

    private def self.checked(type : T.class, value, oid : UInt32) : T forall T
      unless T::MIN <= value <= T::MAX
        raise EncodeError.new("#{value} is out of range for #{OID.name(oid)}")
      end
      T.new!(value)
    end

    private def self.mismatch(oid : UInt32, value) : NoReturn
      raise EncodeError.new("cannot encode #{value.class} as #{OID.name(oid)}")
    end

    private def self.write_interval(io : IO, value : Interval) : Nil
      io.write_bytes(value.microseconds, IO::ByteFormat::BigEndian)
      io.write_bytes(value.days, IO::ByteFormat::BigEndian)
      io.write_bytes(value.months, IO::ByteFormat::BigEndian)
    end

    # NUMERIC binary form: ndigits, weight, sign, dscale (all Int16) and
    # ndigits base-10000 digits, the first worth 10000^weight.
    def self.write_numeric(io : IO, value : BigDecimal) : Nil
      scale = value.scale.to_i
      unscaled = value.value
      negative = unscaled < 0
      text = unscaled.abs.to_s
      text = text.rjust(scale + 1, '0') if text.size <= scale
      int_part = text[0, text.size - scale]
      frac_part = text[text.size - scale, scale]
      int_part = int_part.rjust((int_part.size + 3) // 4 * 4, '0')
      frac_part = frac_part.ljust((frac_part.size + 3) // 4 * 4, '0')
      digits = [] of Int16
      int_part.each_char.each_slice(4) { |g| digits << g.join.to_i16 }
      weight = digits.size - 1
      frac_part.each_char.each_slice(4) { |g| digits << g.join.to_i16 }
      while digits.first? == 0
        digits.shift
        weight -= 1
      end
      while digits.last? == 0
        digits.pop
      end
      weight = 0 if digits.empty?
      if scale > Int16::MAX || weight.abs > Int16::MAX || digits.size > Int16::MAX
        raise EncodeError.new("numeric value out of range")
      end
      io.write_bytes(digits.size.to_i16, IO::ByteFormat::BigEndian)
      io.write_bytes(weight.to_i16, IO::ByteFormat::BigEndian)
      io.write_bytes(negative && !digits.empty? ? 0x4000_u16 : 0_u16, IO::ByteFormat::BigEndian)
      io.write_bytes(scale.to_i16, IO::ByteFormat::BigEndian)
      digits.each { |d| io.write_bytes(d, IO::ByteFormat::BigEndian) }
    end

    # --- decoding ---------------------------------------------------------

    def self.decode(b : Bytes, c : Column, type : Bool.class) : Bool
      mismatch(c, type) unless c.binary? && c.type_oid == OID::BOOL && b.size == 1
      b[0] != 0
    end

    def self.decode(b : Bytes, c : Column, type : Int16.class) : Int16
      mismatch(c, type) unless c.binary? && c.type_oid == OID::INT2
      int(b, c, Int16)
    end

    def self.decode(b : Bytes, c : Column, type : Int32.class) : Int32
      mismatch(c, type) unless c.binary?
      case c.type_oid
      when OID::INT4 then int(b, c, Int32)
      when OID::INT2 then int(b, c, Int16).to_i32
      else                mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : Int64.class) : Int64
      mismatch(c, type) unless c.binary?
      case c.type_oid
      when OID::INT8 then int(b, c, Int64)
      when OID::INT4 then int(b, c, Int32).to_i64
      when OID::INT2 then int(b, c, Int16).to_i64
      else                mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : UInt32.class) : UInt32
      mismatch(c, type) unless c.binary? && c.type_oid == OID::OID
      int(b, c, UInt32)
    end

    def self.decode(b : Bytes, c : Column, type : Float32.class) : Float32
      mismatch(c, type) unless c.binary? && c.type_oid == OID::FLOAT4
      int(b, c, Float32)
    end

    def self.decode(b : Bytes, c : Column, type : Float64.class) : Float64
      mismatch(c, type) unless c.binary?
      case c.type_oid
      when OID::FLOAT8 then int(b, c, Float64)
      when OID::FLOAT4 then int(b, c, Float32).to_f64
      else                  mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : BigDecimal.class) : BigDecimal
      mismatch(c, type) unless c.binary?
      case c.type_oid
      when OID::NUMERIC then read_numeric(b, c)
      when OID::INT8    then BigDecimal.new(int(b, c, Int64))
      when OID::INT4    then BigDecimal.new(int(b, c, Int32))
      when OID::INT2    then BigDecimal.new(int(b, c, Int16))
      else                   mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : String.class) : String
      return String.new(b) unless c.binary?
      case c.type_oid
      when OID::TEXT, OID::VARCHAR, OID::BPCHAR, OID::NAME, OID::CHAR, OID::UNKNOWN, OID::JSON
        String.new(b)
      when OID::JSONB
        jsonb(b, c)
      else
        mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : Bytes.class) : Bytes
      mismatch(c, type) unless c.binary? && c.type_oid == OID::BYTEA
      b.dup
    end

    def self.decode(b : Bytes, c : Column, type : UUID.class) : UUID
      mismatch(c, type) unless c.binary? && c.type_oid == OID::UUID && b.size == 16
      bytes = uninitialized UInt8[16]
      b.copy_to(bytes.to_slice)
      UUID.new(bytes)
    end

    def self.decode(b : Bytes, c : Column, type : Time.class) : Time
      mismatch(c, type) unless c.binary?
      case c.type_oid
      when OID::TIMESTAMPTZ, OID::TIMESTAMP
        us = int(b, c, Int64)
        if us == Int64::MAX || us == Int64::MIN
          raise DecodeError.new("column #{c.name.inspect}: #{us > 0 ? "" : "-"}infinity cannot be a Time")
        end
        Time.unix(PG_EPOCH_UNIX + (us // 1_000_000)) + Time::Span.new(nanoseconds: (us % 1_000_000) * 1000)
      when OID::DATE
        days = int(b, c, Int32)
        if days == Int32::MAX || days == Int32::MIN
          raise DecodeError.new("column #{c.name.inspect}: #{days > 0 ? "" : "-"}infinity cannot be a Time")
        end
        Time.unix((PG_EPOCH_DAYS + days) * 86_400)
      else
        mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : Time::Span.class) : Time::Span
      mismatch(c, type) unless c.binary?
      case c.type_oid
      when OID::TIME
        Time::Span.new(nanoseconds: int(b, c, Int64) * 1000)
      when OID::INTERVAL
        interval = read_interval(b, c)
        unless interval.months == 0
          raise DecodeError.new("column #{c.name.inspect}: an interval of #{interval.months} months cannot be a Time::Span; use Postgres::Interval")
        end
        interval.to_span
      else
        mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : Interval.class) : Interval
      mismatch(c, type) unless c.binary? && c.type_oid == OID::INTERVAL
      read_interval(b, c)
    end

    def self.decode(b : Bytes, c : Column, type : JSON::Any.class) : JSON::Any
      mismatch(c, type) unless c.binary?
      case c.type_oid
      when OID::JSON  then JSON.parse(String.new(b))
      when OID::JSONB then JSON.parse(jsonb(b, c))
      else                 mismatch(c, type)
      end
    end

    # A one-dimensional array (an empty one has no dimensions). Elements
    # decode like columns of the element type; a nilable element type
    # reads NULL elements as `nil`.
    def self.decode(b : Bytes, c : Column, type : Array(T).class) : Array(T) forall T
      element = c.binary? ? OID.element(c.type_oid) : nil
      mismatch(c, type) unless element
      raise DecodeError.new("column #{c.name.inspect}: truncated array") if b.size < 12
      dimensions = IO::ByteFormat::BigEndian.decode(Int32, b)
      return [] of T if dimensions == 0
      unless dimensions == 1
        raise DecodeError.new("column #{c.name.inspect}: a #{dimensions}-dimensional array cannot be decoded as #{type}")
      end
      raise DecodeError.new("column #{c.name.inspect}: truncated array") if b.size < 20
      count = IO::ByteFormat::BigEndian.decode(Int32, b + 12)
      raise DecodeError.new("column #{c.name.inspect}: negative array size") if count < 0
      element_column = Column.new(c.name, IO::ByteFormat::BigEndian.decode(UInt32, b + 8))
      pos = 20
      Array(T).new(count) do
        raise DecodeError.new("column #{c.name.inspect}: truncated array") if pos + 4 > b.size
        size = IO::ByteFormat::BigEndian.decode(Int32, b + pos)
        pos += 4
        if size < 0
          {% if T.nilable? %}
            nil
          {% else %}
            raise DecodeError.new("column #{c.name.inspect}: NULL element but #{T} is not nilable")
          {% end %}
        else
          raise DecodeError.new("column #{c.name.inspect}: truncated array") if pos + size > b.size
          item = b[pos, size]
          pos += size
          {% if T.nilable? %}
            {% inner = T.union_types.reject(&.==(Nil)) %}
            {% raise "Postgres: array element #{T} must be a single type or a single type plus Nil" unless inner.size == 1 %}
            decode(item, element_column, {{ inner[0] }})
          {% else %}
            decode(item, element_column, T)
          {% end %}
        end
      end
    end

    private def self.int(b : Bytes, c : Column, type : T.class) : T forall T
      raise DecodeError.new("column #{c.name.inspect}: expected #{sizeof(T)} bytes for #{OID.name(c.type_oid)}, got #{b.size}") unless b.size == sizeof(T)
      IO::ByteFormat::BigEndian.decode(T, b)
    end

    private def self.jsonb(b : Bytes, c : Column) : String
      unless b.size >= 1 && b[0] == 1
        raise DecodeError.new("column #{c.name.inspect}: unsupported jsonb version #{b[0]?}")
      end
      String.new(b + 1)
    end

    private def self.read_interval(b : Bytes, c : Column) : Interval
      raise DecodeError.new("column #{c.name.inspect}: expected 16 bytes for interval, got #{b.size}") unless b.size == 16
      Interval.new(
        microseconds: IO::ByteFormat::BigEndian.decode(Int64, b),
        days: IO::ByteFormat::BigEndian.decode(Int32, b + 8),
        months: IO::ByteFormat::BigEndian.decode(Int32, b + 12))
    end

    private def self.read_numeric(b : Bytes, c : Column) : BigDecimal
      raise DecodeError.new("column #{c.name.inspect}: truncated numeric") if b.size < 8
      ndigits = IO::ByteFormat::BigEndian.decode(Int16, b).to_i
      weight = IO::ByteFormat::BigEndian.decode(Int16, b + 2).to_i
      sign = IO::ByteFormat::BigEndian.decode(UInt16, b + 4)
      dscale = IO::ByteFormat::BigEndian.decode(Int16, b + 6).to_i
      case sign
      when 0xC000 then raise DecodeError.new("column #{c.name.inspect}: NaN cannot be a BigDecimal")
      when 0xD000 then raise DecodeError.new("column #{c.name.inspect}: Infinity cannot be a BigDecimal")
      when 0xF000 then raise DecodeError.new("column #{c.name.inspect}: -Infinity cannot be a BigDecimal")
      end
      raise DecodeError.new("column #{c.name.inspect}: truncated numeric") if ndigits < 0 || dscale < 0 || b.size != 8 + ndigits * 2
      unscaled = BigInt.new(0)
      ndigits.times do |i|
        unscaled = unscaled * 10000 + IO::ByteFormat::BigEndian.decode(Int16, b + 8 + i * 2)
      end
      # value = unscaled * 10000^(weight - ndigits + 1); scale it by 10^dscale.
      exponent = 4 * (weight - ndigits + 1) + dscale
      if exponent >= 0
        unscaled *= BigInt.new(10) ** exponent
      else
        unscaled //= BigInt.new(10) ** -exponent
      end
      unscaled = -unscaled if sign == 0x4000
      BigDecimal.new(unscaled, dscale.to_u64)
    end

    private def self.mismatch(c : Column, type) : NoReturn
      how = c.binary? ? OID.name(c.type_oid) : "#{OID.name(c.type_oid)} (text format)"
      raise DecodeError.new("column #{c.name.inspect} of type #{how} cannot be decoded as #{type}")
    end
  end
end
