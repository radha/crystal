require "socket"
require "bit_array"

module Postgres
  # An `inet` or `cidr` value: an IPv4 or IPv6 address with a prefix
  # length.
  #
  # ```
  # net = Postgres::Inet.parse("10.1.2.3/8")
  # net.address                      # => "10.1.2.3"
  # net.prefix                       # => 8
  # net.to_s                         # => "10.1.2.3/8"
  # Postgres::Inet.parse("::1").to_s # => "::1"
  # ```
  struct Inet
    # The address bytes: 4 for IPv4, 16 for IPv6.
    getter bytes : Bytes
    # The prefix length (32 or 128 for a single host).
    getter prefix : Int32
    # Whether the value came from (or is meant for) a `cidr` column.
    getter? cidr : Bool

    # Creates a value from address *bytes* (4 or 16) and *prefix*. Raises
    # `ArgumentError` for another size or a prefix out of range.
    def initialize(@bytes : Bytes, prefix : Int32? = nil, *, @cidr : Bool = false)
      raise ArgumentError.new("an address has 4 or 16 bytes, got #{@bytes.size}") unless @bytes.size == 4 || @bytes.size == 16
      max = @bytes.size * 8
      @prefix = prefix || max
      raise ArgumentError.new("prefix #{@prefix} out of range 0..#{max}") unless 0 <= @prefix <= max
    end

    # Parses `"10.0.0.1"`, `"10.0.0.0/8"`, `"2001:db8::1/64"`. Raises
    # `ArgumentError` for anything else.
    def self.parse(text : String, *, cidr : Bool = false) : self
      address, slash, prefix = text.partition('/')
      bits = slash.empty? ? nil : (prefix.to_i? || raise ArgumentError.new("invalid prefix in #{text.inspect}"))
      if fields = Socket::IPAddress.parse_v4_fields?(address)
        new(Bytes.new(4) { |i| fields[i] }, bits, cidr: cidr)
      elsif fields = Socket::IPAddress.parse_v6_fields?(address)
        bytes = Bytes.new(16)
        fields.each_with_index do |field, i|
          bytes[i * 2] = (field >> 8).to_u8
          bytes[i * 2 + 1] = (field & 0xFF).to_u8
        end
        new(bytes, bits, cidr: cidr)
      else
        raise ArgumentError.new("invalid IP address #{text.inspect}")
      end
    end

    # The value for *address* (its port is ignored) as a single host.
    def self.new(address : Socket::IPAddress) : self
      parse(address.address)
    end

    # Whether this is an IPv6 value.
    def ipv6? : Bool
      @bytes.size == 16
    end

    # The address alone, canonically formatted.
    def address : String
      ip_address.address
    end

    # The address as a `Socket::IPAddress` with port 0.
    def ip_address : Socket::IPAddress
      if ipv6?
        fields = StaticArray(UInt16, 8).new { |i| (@bytes[i * 2].to_u16 << 8) | @bytes[i * 2 + 1] }
        Socket::IPAddress.v6(fields, 0_u16)
      else
        Socket::IPAddress.v4(StaticArray(UInt8, 4).new { |i| @bytes[i] }, 0_u16)
      end
    end

    # `address/prefix`, omitting the prefix of a single-host `inet` as
    # PostgreSQL does.
    def to_s(io : IO) : Nil
      io << address
      io << '/' << @prefix if @cidr || @prefix != @bytes.size * 8
    end

    def ==(other : Inet) : Bool
      @bytes == other.bytes && @prefix == other.prefix
    end

    # :nodoc:
    def hash(hasher)
      hasher = @bytes.hash(hasher)
      @prefix.hash(hasher)
    end
  end

  # A `macaddr` (6 bytes) or `macaddr8` (8 bytes) value.
  struct MacAddress
    # The address bytes.
    getter bytes : Bytes

    # Creates a value from 6 or 8 *bytes*.
    def initialize(@bytes : Bytes)
      raise ArgumentError.new("a MAC address has 6 or 8 bytes, got #{@bytes.size}") unless @bytes.size == 6 || @bytes.size == 8
    end

    # Parses `"08:00:2b:01:02:03"` (also `-` separated).
    def self.parse(text : String) : self
      parts = text.split(/[:\-]/)
      bytes = parts.map { |p| p.to_u8?(16) || raise ArgumentError.new("invalid MAC address #{text.inspect}") }
      new(Bytes.new(bytes.size) { |i| bytes[i] })
    end

    # Lowercase, colon separated.
    def to_s(io : IO) : Nil
      @bytes.each_with_index do |b, i|
        io << ':' if i > 0
        io << b.to_s(16).rjust(2, '0')
      end
    end

    def ==(other : MacAddress) : Bool
      @bytes == other.bytes
    end

    # :nodoc:
    def hash(hasher)
      @bytes.hash(hasher)
    end
  end

  # A `timetz` value: a time of day and a fixed UTC offset.
  struct TimeTz
    # Time since midnight.
    getter time : Time::Span
    # Offset from UTC in seconds, east positive (`+02` → 7200).
    getter offset : Int32

    def initialize(@time : Time::Span, @offset : Int32 = 0)
    end

    # The offset as a `Time::Location`.
    def location : Time::Location
      Time::Location.fixed(@offset)
    end

    # `13:14:15.5+02:00`.
    def to_s(io : IO) : Nil
      total = @time.total_nanoseconds.to_i64
      hours, rest = total.divmod(3_600_000_000_000)
      minutes, rest = rest.divmod(60_000_000_000)
      seconds, nanos = rest.divmod(1_000_000_000)
      io << hours.to_s.rjust(2, '0') << ':' << minutes.to_s.rjust(2, '0') << ':' << seconds.to_s.rjust(2, '0')
      io << '.' << nanos.to_s.rjust(9, '0').rstrip('0') unless nanos == 0
      sign = @offset < 0 ? '-' : '+'
      oh, om = @offset.abs.divmod(3600)
      io << sign << oh.to_s.rjust(2, '0') << ':' << (om // 60).to_s.rjust(2, '0')
    end
  end

  # A PostgreSQL range (`int4range`, `int8range`, `numrange`, `tsrange`,
  # `tstzrange`, `daterange`) of `T`: bounds may be absent (unbounded)
  # and each is inclusive or exclusive; a range may be empty.
  #
  # ```
  # r = Postgres::Range(Int32).new(1, 10)                          # [1,10)
  # r.includes?(9)                                                 # => true
  # r.to_s                                                         # => "[1,10)"
  # Postgres::Range(Int32).new(nil, 5, upper_inclusive: true).to_s # => "(,5]"
  # ```
  #
  # A Crystal `::Range` can be passed as a parameter for a range column
  # (`1..10` is `[1,10]`, `1...10` is `[1,10)`, `1..` is `[1,)`).
  struct Range(T)
    # The lower bound, or nil when unbounded (or empty).
    getter lower : T?
    # The upper bound, or nil when unbounded (or empty).
    getter upper : T?
    # Whether `lower` itself is in the range.
    getter? lower_inclusive : Bool
    # Whether `upper` itself is in the range.
    getter? upper_inclusive : Bool
    # Whether the range is `empty`.
    getter? empty : Bool

    # Creates a range; the default bounds are `[lower,upper)`, as
    # PostgreSQL's constructors. An absent bound is never inclusive.
    def initialize(@lower : T?, @upper : T?, *, lower_inclusive : Bool = true, upper_inclusive : Bool = false)
      @lower_inclusive = lower_inclusive && !@lower.nil?
      @upper_inclusive = upper_inclusive && !@upper.nil?
      @empty = false
    end

    # The `empty` range.
    def self.empty : self
      range = new(nil, nil)
      range.mark_empty
      range
    end

    protected def mark_empty : Nil
      @empty = true
    end

    # :nodoc:
    def self.new(*, lower : T?, upper : T?, lower_inclusive : Bool, upper_inclusive : Bool, empty : Bool) : self
      empty ? self.empty : new(lower, upper, lower_inclusive: lower_inclusive, upper_inclusive: upper_inclusive)
    end

    # Whether *value* is in the range.
    def includes?(value : T) : Bool
      return false if @empty
      if l = @lower
        return false if @lower_inclusive ? value < l : value <= l
      end
      if u = @upper
        return false if @upper_inclusive ? value > u : value >= u
      end
      true
    end

    # PostgreSQL's text form: `[1,10)`, `(,5]`, `empty`.
    def to_s(io : IO) : Nil
      return io << "empty" if @empty
      io << (@lower_inclusive ? '[' : '(')
      @lower.try { |l| io << l }
      io << ','
      @upper.try { |u| io << u }
      io << (@upper_inclusive ? ']' : ')')
    end

    def ==(other : Range) : Bool
      return @empty == other.empty? if @empty || other.empty?
      @lower == other.lower && @upper == other.upper &&
        @lower_inclusive == other.lower_inclusive? && @upper_inclusive == other.upper_inclusive?
    end
  end
end
