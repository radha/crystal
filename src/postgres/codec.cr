require "big"
require "uuid"
require "json"
require "./error"
require "./oid"
require "./interval"
require "./types"
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
      when OID::MONEY
        io.write_bytes(value.to_i64, IO::ByteFormat::BigEndian)
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
      when OID::TEXT, OID::VARCHAR, OID::BPCHAR, OID::NAME, OID::CHAR, OID::UNKNOWN, OID::JSON, OID::XML
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
      dimensions = array_shape(value)
      body = IO::Memory.new
      has_null = write_array_elements(body, element, value, dimensions, 0)
      return encode_array_text(io, value) if has_null.nil?
      empty = dimensions.any?(0)
      io.write_bytes(empty ? 0_i32 : dimensions.size.to_i32, IO::ByteFormat::BigEndian)
      io.write_bytes(has_null ? 1_i32 : 0_i32, IO::ByteFormat::BigEndian)
      io.write_bytes(element, IO::ByteFormat::BigEndian)
      unless empty
        dimensions.each do |size|
          io.write_bytes(size.to_i32, IO::ByteFormat::BigEndian)
          io.write_bytes(1_i32, IO::ByteFormat::BigEndian) # lower bound
        end
        io.write(body.to_slice)
      end
      BINARY
    end

    # The dimensions of a (nested) array, measured along its first elements.
    private def self.array_shape(value : Array) : Array(Int32)
      dimensions = [value.size]
      first = value.first?
      dimensions.concat(array_shape(first)) if first.is_a?(Array)
      dimensions
    end

    # Writes the elements of *value* at *depth* in row-major order, checking
    # that the array is rectangular. Returns whether a NULL was written, or
    # nil when an element cannot go binary (the caller falls back to text).
    private def self.write_array_elements(body : IO::Memory, element : UInt32, value : Array,
                                          dimensions : Array(Int32), depth : Int32) : Bool?
      unless value.size == dimensions[depth]
        raise EncodeError.new("arrays must be rectangular: expected #{dimensions[depth]} elements at depth #{depth + 1}, got #{value.size}")
      end
      has_null = false
      value.each do |item|
        if depth < dimensions.size - 1
          unless item.is_a?(Array)
            raise EncodeError.new("arrays must be rectangular: #{item.class} where an array was expected at depth #{depth + 2}")
          end
          nested = write_array_elements(body, element, item, dimensions, depth + 1)
          return nil if nested.nil?
          has_null ||= nested
        elsif item.nil?
          has_null = true
          body.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
        elsif item.is_a?(Array)
          raise EncodeError.new("arrays must be rectangular: an array nested deeper than the first element")
        else
          length_at = body.pos
          body.write_bytes(0_i32, IO::ByteFormat::BigEndian)
          return nil unless encode(body, element, item) == BINARY
          IO::ByteFormat::BigEndian.encode((body.pos - length_at - 4).to_i32, body.to_slice + length_at)
        end
      end
      has_null
    end

    private def self.encode_array_text(io : IO, value : Array) : Int16
      io << '{'
      value.each_with_index do |item, i|
        io << ',' if i > 0
        if item.nil?
          io << "NULL"
        elsif item.is_a?(Array)
          encode_array_text(io, item)
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

    def self.encode(io : IO, oid : UInt32, value : Inet) : Int16
      case oid
      when OID::INET, OID::CIDR
        io.write_byte(value.ipv6? ? 3_u8 : 2_u8) # PGSQL_AF_INET(6)
        io.write_byte(value.prefix.to_u8)
        io.write_byte(oid == OID::CIDR ? 1_u8 : 0_u8)
        io.write_byte(value.bytes.size.to_u8)
        io.write(value.bytes)
        BINARY
      else
        return encode(io, oid, value.to_s) if OID.text?(oid)
        mismatch(oid, value)
      end
    end

    def self.encode(io : IO, oid : UInt32, value : Socket::IPAddress) : Int16
      encode(io, oid, Inet.new(value))
    end

    def self.encode(io : IO, oid : UInt32, value : MacAddress) : Int16
      unless (oid == OID::MACADDR && value.bytes.size == 6) || (oid == OID::MACADDR8 && value.bytes.size == 8)
        return encode(io, oid, value.to_s) if OID.text?(oid)
        mismatch(oid, value)
      end
      io.write(value.bytes)
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : TimeTz) : Int16
      mismatch(oid, value) unless oid == OID::TIMETZ
      io.write_bytes(value.time.total_nanoseconds.to_i64 // 1000, IO::ByteFormat::BigEndian)
      io.write_bytes(-value.offset, IO::ByteFormat::BigEndian) # the wire counts seconds west
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : BitArray) : Int16
      mismatch(oid, value) unless oid == OID::BIT || oid == OID::VARBIT
      io.write_bytes(value.size.to_i32, IO::ByteFormat::BigEndian)
      bytes = Bytes.new((value.size + 7) // 8)
      value.each_with_index { |bit, i| bytes[i // 8] |= (0x80_u8 >> (i % 8)) if bit }
      io.write(bytes)
      BINARY
    end

    def self.encode(io : IO, oid : UInt32, value : Range) : Int16
      write_range(io, oid, value, value.lower, value.upper, value.lower_inclusive?, value.upper_inclusive?, value.empty?)
    end

    # A Crystal range: `a..b` is `[a,b]`, `a...b` is `[a,b)`, a nil end is
    # unbounded.
    def self.encode(io : IO, oid : UInt32, value : ::Range) : Int16
      write_range(io, oid, value, value.begin, value.end, true, !value.excludes_end?, false)
    end

    private def self.write_range(io : IO, oid : UInt32, value, lower, upper, lower_inclusive : Bool,
                                 upper_inclusive : Bool, empty : Bool) : Int16
      element = OID.range_element(oid) || mismatch(oid, value)
      if empty
        io.write_byte(0x01_u8)
        return BINARY
      end
      flags = 0_u8
      flags |= 0x02_u8 if lower_inclusive && !lower.nil?
      flags |= 0x04_u8 if upper_inclusive && !upper.nil?
      flags |= 0x08_u8 if lower.nil?
      flags |= 0x10_u8 if upper.nil?
      io.write_byte(flags)
      {lower, upper}.each do |bound|
        next if bound.nil?
        scratch = IO::Memory.new
        unless encode(scratch, element, bound) == BINARY
          raise EncodeError.new("cannot encode #{bound.class} as a #{OID.name(oid)} bound")
        end
        io.write_bytes(scratch.pos.to_i32, IO::ByteFormat::BigEndian)
        io.write(scratch.to_slice)
      end
      BINARY
    end

    # A `Hash(String, String?)` as an `hstore` (an extension type, sent in
    # its text form: `"k"=>"v", "n"=>NULL`).
    def self.encode(io : IO, oid : UInt32, value : Hash) : Int16
      mismatch(oid, value) if OID.binary?(oid)
      value.each_with_index do |(key, item), i|
        io << ", " if i > 0
        hstore_quote(io, key.to_s)
        io << "=>"
        item.nil? ? (io << "NULL") : hstore_quote(io, item.to_s)
      end
      TEXT
    end

    private def self.hstore_quote(io : IO, text : String) : Nil
      io << '"'
      text.each_char do |char|
        io << '\\' if char == '"' || char == '\\'
        io << char
      end
      io << '"'
    end

    # A `Tuple` as a composite (row) value, sent as a row literal the server
    # parses by the composite's own field types: `(1,"a b",)`, NULL for
    # nil. Fields are written with `to_s`, so keep them to scalars.
    def self.encode(io : IO, oid : UInt32, value : Tuple) : Int16
      mismatch(oid, value) if OID.binary?(oid) && oid != OID::RECORD
      io << '('
      value.each_with_index do |item, i|
        io << ',' if i > 0
        next if item.nil?
        io << '"'
        text = item.is_a?(Time) ? item.to_utc.to_s("%F %T.%6N+00") : item.to_s
        text.each_char do |char|
          io << char if char == '"' || char == '\\'
          io << char
        end
        io << '"'
      end
      io << ')'
      TEXT
    end

    # An enum: its value for an integer parameter, otherwise its name in
    # `snake_case` (`Status::OnHold` → `"on_hold"`), matching the usual
    # spelling of PostgreSQL enum labels.
    def self.encode(io : IO, oid : UInt32, value : Enum) : Int16
      case oid
      when OID::INT2, OID::INT4, OID::INT8
        encode(io, oid, value.value.to_i64)
      else
        encode(io, oid, value.to_s.underscore)
      end
    end

    # Any other value: encoded as whatever its `to_pg` method returns
    # (a user type's hook), or `EncodeError`.
    def self.encode(io : IO, oid : UInt32, value) : Int16
      if value.responds_to?(:to_pg)
        encode(io, oid, value.to_pg)
      else
        mismatch(oid, value)
      end
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
      mismatch(c, type) unless c.binary? && c.codec_oid == OID::BOOL && b.size == 1
      b[0] != 0
    end

    def self.decode(b : Bytes, c : Column, type : Int16.class) : Int16
      mismatch(c, type) unless c.binary? && c.codec_oid == OID::INT2
      int(b, c, Int16)
    end

    def self.decode(b : Bytes, c : Column, type : Int32.class) : Int32
      mismatch(c, type) unless c.binary?
      case c.codec_oid
      when OID::INT4 then int(b, c, Int32)
      when OID::INT2 then int(b, c, Int16).to_i32
      else                mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : Int64.class) : Int64
      mismatch(c, type) unless c.binary?
      case c.codec_oid
      when OID::INT8  then int(b, c, Int64)
      when OID::INT4  then int(b, c, Int32).to_i64
      when OID::INT2  then int(b, c, Int16).to_i64
      when OID::MONEY then int(b, c, Int64) # minor units (cents)
      else                 mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : UInt32.class) : UInt32
      mismatch(c, type) unless c.binary? && c.codec_oid == OID::OID
      int(b, c, UInt32)
    end

    def self.decode(b : Bytes, c : Column, type : Float32.class) : Float32
      mismatch(c, type) unless c.binary? && c.codec_oid == OID::FLOAT4
      int(b, c, Float32)
    end

    def self.decode(b : Bytes, c : Column, type : Float64.class) : Float64
      mismatch(c, type) unless c.binary?
      case c.codec_oid
      when OID::FLOAT8 then int(b, c, Float64)
      when OID::FLOAT4 then int(b, c, Float32).to_f64
      else                  mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : BigDecimal.class) : BigDecimal
      mismatch(c, type) unless c.binary?
      case c.codec_oid
      when OID::NUMERIC then read_numeric(b, c)
      when OID::INT8    then BigDecimal.new(int(b, c, Int64))
      when OID::INT4    then BigDecimal.new(int(b, c, Int32))
      when OID::INT2    then BigDecimal.new(int(b, c, Int16))
      else                   mismatch(c, type)
      end
    end

    def self.decode(b : Bytes, c : Column, type : String.class) : String
      return String.new(b) unless c.binary?
      case c.codec_oid
      when OID::TEXT, OID::VARCHAR, OID::BPCHAR, OID::NAME, OID::CHAR, OID::UNKNOWN, OID::JSON, OID::XML
        String.new(b)
      when OID::JSONB
        jsonb(b, c)
      when OID::INET, OID::CIDR        then decode(b, c, Inet).to_s
      when OID::MACADDR, OID::MACADDR8 then decode(b, c, MacAddress).to_s
      when OID::TIMETZ                 then decode(b, c, TimeTz).to_s
      when OID::BIT, OID::VARBIT       then String.build { |s| decode(b, c, BitArray).each { |bit| s << (bit ? '1' : '0') } }
      else
        if OID.range_element(c.codec_oid)
          range_text(b, c)
        else
          mismatch(c, type)
        end
      end
    end

    def self.decode(b : Bytes, c : Column, type : Bytes.class) : Bytes
      mismatch(c, type) unless c.binary? && c.codec_oid == OID::BYTEA
      b.dup
    end

    def self.decode(b : Bytes, c : Column, type : UUID.class) : UUID
      mismatch(c, type) unless c.binary? && c.codec_oid == OID::UUID && b.size == 16
      bytes = uninitialized UInt8[16]
      b.copy_to(bytes.to_slice)
      UUID.new(bytes)
    end

    def self.decode(b : Bytes, c : Column, type : Time.class) : Time
      mismatch(c, type) unless c.binary?
      case c.codec_oid
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
      case c.codec_oid
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
      mismatch(c, type) unless c.binary? && c.codec_oid == OID::INTERVAL
      read_interval(b, c)
    end

    def self.decode(b : Bytes, c : Column, type : JSON::Any.class) : JSON::Any
      mismatch(c, type) unless c.binary?
      case c.codec_oid
      when OID::JSON  then JSON.parse(String.new(b))
      when OID::JSONB then JSON.parse(jsonb(b, c))
      else                 mismatch(c, type)
      end
    end

    # A one-dimensional array (an empty one has no dimensions). Elements
    # decode like columns of the element type; a nilable element type
    # reads NULL elements as `nil`.
    def self.decode(b : Bytes, c : Column, type : Array(T).class) : Array(T) forall T
      element = c.binary? ? OID.element(c.codec_oid) : nil
      mismatch(c, type) unless element
      raise DecodeError.new("column #{c.name.inspect}: truncated array") if b.size < 12
      dimensions = IO::ByteFormat::BigEndian.decode(Int32, b)
      return [] of T if dimensions == 0
      unless 0 < dimensions <= 6 && b.size >= 12 + 8 * dimensions
        raise DecodeError.new("column #{c.name.inspect}: malformed array header")
      end
      unless dimensions == array_depth(type)
        raise DecodeError.new("column #{c.name.inspect}: a #{dimensions}-dimensional array cannot be decoded as #{type}")
      end
      sizes = Array(Int32).new(dimensions) do |d|
        size = IO::ByteFormat::BigEndian.decode(Int32, b + 12 + d * 8)
        raise DecodeError.new("column #{c.name.inspect}: negative array size") if size < 0
        size
      end
      element_column = Column.new(c.name, IO::ByteFormat::BigEndian.decode(UInt32, b + 8), types: c.types)
      build_array(type, sizes, 0, ArrayCursor.new(b, 12 + 8 * dimensions, element_column))
    end

    # The nesting depth of an `Array` type: 1 for `Array(Int32)`, 2 for
    # `Array(Array(Int32))`.
    def self.array_depth(type : Array(T).class) : Int32 forall T
      {% if T < Array %}
        1 + array_depth(T)
      {% else %}
        1
      {% end %}
    end

    # One dimension of a (possibly nested) array, in row-major order.
    private def self.build_array(type : Array(T).class, sizes : Array(Int32), depth : Int32, cursor : ArrayCursor) : Array(T) forall T
      Array(T).new(sizes[depth]) do
        {% if T < Array %}
          build_array(T, sizes, depth + 1, cursor)
        {% else %}
          cursor.next(T)
        {% end %}
      end
    end

    # :nodoc:
    #
    # Walks the elements of a binary array.
    class ArrayCursor
      def initialize(@bytes : Bytes, @pos : Int32, @column : Column)
      end

      def next(type : T.class) : T forall T
        b = @bytes
        c = @column
        raise DecodeError.new("column #{c.name.inspect}: truncated array") if @pos + 4 > b.size
        size = IO::ByteFormat::BigEndian.decode(Int32, b + @pos)
        @pos += 4
        if size < 0
          {% if T.nilable? %}
            return nil
          {% else %}
            raise DecodeError.new("column #{c.name.inspect}: NULL element but #{T} is not nilable")
          {% end %}
        end
        raise DecodeError.new("column #{c.name.inspect}: truncated array") if @pos + size > b.size
        item = b[@pos, size]
        @pos += size
        {% if T.nilable? %}
          {% raise "Postgres: array element #{T} must be a single type or a single type plus Nil" unless T.union_types.size == 2 %}
          Codec.decode(item, c, typeof(Pointer(T).null.value.not_nil!))
        {% else %}
          Codec.decode(item, c, T)
        {% end %}
      end
    end

    def self.decode(b : Bytes, c : Column, type : Inet.class) : Inet
      mismatch(c, type) unless c.binary? && (c.codec_oid == OID::INET || c.codec_oid == OID::CIDR)
      unless b.size >= 4 && b.size == 4 + b[3]
        raise DecodeError.new("column #{c.name.inspect}: malformed #{OID.name(c.codec_oid)}")
      end
      Inet.new(b[4, b[3]].dup, b[1].to_i, cidr: b[2] == 1)
    rescue ex : ArgumentError
      raise DecodeError.new("column #{c.name.inspect}: #{ex.message}")
    end

    # The address of an `inet` (its prefix is dropped), port 0.
    def self.decode(b : Bytes, c : Column, type : Socket::IPAddress.class) : Socket::IPAddress
      decode(b, c, Inet).ip_address
    end

    def self.decode(b : Bytes, c : Column, type : MacAddress.class) : MacAddress
      mismatch(c, type) unless c.binary? && (c.codec_oid == OID::MACADDR || c.codec_oid == OID::MACADDR8)
      MacAddress.new(b.dup)
    rescue ex : ArgumentError
      raise DecodeError.new("column #{c.name.inspect}: #{ex.message}")
    end

    def self.decode(b : Bytes, c : Column, type : TimeTz.class) : TimeTz
      mismatch(c, type) unless c.binary? && c.codec_oid == OID::TIMETZ
      raise DecodeError.new("column #{c.name.inspect}: expected 12 bytes for timetz, got #{b.size}") unless b.size == 12
      TimeTz.new(Time::Span.new(nanoseconds: IO::ByteFormat::BigEndian.decode(Int64, b) * 1000),
        -IO::ByteFormat::BigEndian.decode(Int32, b + 8))
    end

    def self.decode(b : Bytes, c : Column, type : BitArray.class) : BitArray
      mismatch(c, type) unless c.binary? && (c.codec_oid == OID::BIT || c.codec_oid == OID::VARBIT)
      raise DecodeError.new("column #{c.name.inspect}: truncated bit string") if b.size < 4
      size = IO::ByteFormat::BigEndian.decode(Int32, b)
      raise DecodeError.new("column #{c.name.inspect}: truncated bit string") if size < 0 || b.size < 4 + (size + 7) // 8
      bits = BitArray.new(size)
      size.times { |i| bits[i] = b[4 + i // 8].bit(7 - i % 8) == 1 }
      bits
    end

    # An `hstore` (in its text form; NULL values are nil).
    def self.decode(b : Bytes, c : Column, type : Hash(String, String?).class) : Hash(String, String?)
      mismatch(c, type) if c.binary?
      HstoreParser.new(String.new(b), c).parse
    end

    # :nodoc:
    private struct HstoreParser
      def initialize(@text : String, @column : Column)
        @reader = Char::Reader.new(@text)
      end

      def parse : Hash(String, String?)
        hash = {} of String => String?
        skip_spaces
        until @reader.current_char == '\0' && !@reader.has_next?
          key = token || fail("expected a key")
          skip_spaces
          expect('=')
          expect('>')
          skip_spaces
          quoted = @reader.current_char == '"'
          value = token || fail("expected a value")
          hash[key] = (!quoted && value.compare("NULL", case_insensitive: true) == 0) ? nil : value
          skip_spaces
          break unless @reader.current_char == ','
          @reader.next_char
          skip_spaces
        end
        hash
      end

      # A quoted string with backslash escapes, or a bare word.
      private def token : String?
        quoted = @reader.current_char == '"'
        text = String.build do |s|
          if quoted
            loop do
              char = @reader.next_char
              fail("unterminated string") if char == '\0' && !@reader.has_next?
              break if char == '"'
              char = @reader.next_char if char == '\\'
              s << char
            end
            @reader.next_char
          else
            while (char = @reader.current_char) != '\0' && !char.whitespace? && char != '=' && char != ','
              s << char
              @reader.next_char
            end
          end
        end
        # "" is a valid (empty) quoted string; a bare word must not be empty.
        quoted || !text.empty? ? text : nil
      end

      private def skip_spaces : Nil
        while @reader.current_char.whitespace?
          @reader.next_char
        end
      end

      private def expect(char : Char) : Nil
        fail("expected #{char.inspect}") unless @reader.current_char == char
        @reader.next_char
      end

      private def fail(message : String) : NoReturn
        raise DecodeError.new("column #{@column.name.inspect}: malformed hstore (#{message}) at #{@reader.pos}")
      end
    end

    # A range of `T` (`Postgres::Range(Int32)` for `int4range`, ...).
    def self.decode(b : Bytes, c : Column, type : Range(T).class) : Range(T) forall T
      element = c.binary? ? OID.range_element(c.codec_oid) : nil
      mismatch(c, type) unless element
      lower, upper, flags = range_bounds(b, c)
      return Range(T).empty if flags.bits_set?(0x01)
      element_column = Column.new(c.name, element, types: c.types)
      Range(T).new(lower.try { |l| decode(l, element_column, T) }, upper.try { |u| decode(u, element_column, T) },
        lower_inclusive: flags.bits_set?(0x02), upper_inclusive: flags.bits_set?(0x04))
    end

    # `{lower bytes, upper bytes, flags}` of a binary range.
    private def self.range_bounds(b : Bytes, c : Column) : {Bytes?, Bytes?, UInt8}
      raise DecodeError.new("column #{c.name.inspect}: truncated range") if b.empty?
      flags = b[0]
      pos = 1
      bounds = {0x08_u8, 0x10_u8}.map do |infinite|
        next nil if flags.bits_set?(0x01) || flags.bits_set?(infinite)
        raise DecodeError.new("column #{c.name.inspect}: truncated range") if pos + 4 > b.size
        size = IO::ByteFormat::BigEndian.decode(Int32, b + pos)
        pos += 4
        raise DecodeError.new("column #{c.name.inspect}: truncated range") if size < 0 || pos + size > b.size
        bound = b[pos, size]
        pos += size
        bound
      end
      {bounds[0], bounds[1], flags}
    end

    # PostgreSQL's text form of a binary range (timestamps in UTC).
    private def self.range_text(b : Bytes, c : Column) : String
      lower, upper, flags = range_bounds(b, c)
      return "empty" if flags.bits_set?(0x01)
      element = Column.new(c.name, OID.range_element(c.codec_oid).not_nil!, types: c.types)
      String.build do |s|
        s << (flags.bits_set?(0x02) ? '[' : '(')
        lower.try { |l| s << bound_text(l, element) }
        s << ','
        upper.try { |u| s << bound_text(u, element) }
        s << (flags.bits_set?(0x04) ? ']' : ')')
      end
    end

    private def self.bound_text(b : Bytes, c : Column) : String
      case c.codec_oid
      when OID::INT4, OID::INT8 then decode(b, c, Int64).to_s
      when OID::NUMERIC         then decode(b, c, BigDecimal).to_s
      when OID::DATE            then decode(b, c, Time).to_s("%F")
      when OID::TIMESTAMP       then %("#{decode(b, c, Time).to_s("%F %T.%6N").rchop(".000000")}")
      else                           %("#{decode(b, c, Time).to_s("%F %T.%6N").rchop(".000000")}+00")
      end
    end

    # An enum, by label from a text column (or a PostgreSQL enum, which
    # arrives in text format; `Enum.parse?` ignores case and underscores)
    # or by value from an integer column. Any other type without a decoder
    # is a compile-time error.
    def self.decode(b : Bytes, c : Column, type : T.class) : T forall T
      {% if T < Enum %}
        if c.binary? && (c.codec_oid == OID::INT2 || c.codec_oid == OID::INT4 || c.codec_oid == OID::INT8)
          number = decode(b, c, Int64)
          T.from_value?(number) || raise DecodeError.new("column #{c.name.inspect}: #{number} is not a value of #{T}")
        else
          label = decode(b, c, String)
          T.parse?(label) || raise DecodeError.new("column #{c.name.inspect}: #{label.inspect} is not a member of #{T}")
        end
      {% elsif T < Tuple %}
        # A composite (row) value, positionally: Int32 field count, then
        # per field its type OID, length (-1: NULL) and bytes.
        mismatch(c, type) unless c.binary? && c.codec_oid == OID::RECORD
        raise DecodeError.new("column #{c.name.inspect}: truncated record") if b.size < 4
        count = IO::ByteFormat::BigEndian.decode(Int32, b)
        unless count == {{ T.type_vars.size }}
          raise DecodeError.new("column #{c.name.inspect}: a record of #{count} fields cannot be decoded as #{T}")
        end
        pos = 4
        {
          {% for i in 0...T.type_vars.size %}
            begin
              raise DecodeError.new("column #{c.name.inspect}: truncated record") if pos + 8 > b.size
              field_oid = IO::ByteFormat::BigEndian.decode(UInt32, b + pos)
              size = IO::ByteFormat::BigEndian.decode(Int32, b + pos + 4)
              pos += 8
              field = Column.new(c.name, field_oid, types: c.types)
              if size < 0
                {% if T.type_vars[i].nilable? %}
                  nil
                {% else %}
                  raise DecodeError.new("column #{c.name.inspect}: field {{ i + 1 }} is NULL but #{typeof(Pointer(T).null.value[{{ i }}])} is not nilable")
                {% end %}
              else
                raise DecodeError.new("column #{c.name.inspect}: truncated record") if pos + size > b.size
                bytes = b[pos, size]
                pos += size
                {% if T.type_vars[i].nilable? %}
                  decode(bytes, field, typeof(Pointer(T).null.value[{{ i }}].not_nil!))
                {% else %}
                  decode(bytes, field, typeof(Pointer(T).null.value[{{ i }}]))
                {% end %}
              end
            end,
          {% end %}
        }
      {% else %}
        {% raise "Postgres cannot decode a column as #{T}: use a supported type, a Postgres::Serializable, or a converter (@[Postgres::Field(converter: ...)])" %}
      {% end %}
    end

    private def self.int(b : Bytes, c : Column, type : T.class) : T forall T
      raise DecodeError.new("column #{c.name.inspect}: expected #{sizeof(T)} bytes for #{OID.name(c.codec_oid)}, got #{b.size}") unless b.size == sizeof(T)
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
      how = c.binary? ? OID.name(c.codec_oid) : "#{OID.name(c.codec_oid)} (text format)"
      raise DecodeError.new("column #{c.name.inspect} of type #{how} cannot be decoded as #{type}")
    end
  end
end
