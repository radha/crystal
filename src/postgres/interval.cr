module Postgres
  # A PostgreSQL `interval`: months, days and microseconds kept apart, as
  # the server does, because a month is not a fixed number of days and a
  # day is not always 24 hours across a DST change.
  #
  # ```
  # iv = Postgres::Interval.new(months: 1, days: 2, microseconds: 3_500_000)
  # iv.to_s                                    # => "P1M2DT3.5S"
  # Postgres::Interval.new(90.minutes).to_span # => 01:30:00
  # ```
  struct Interval
    # Whole months (a year is 12).
    getter months : Int32
    # Whole days.
    getter days : Int32
    # The time part in microseconds.
    getter microseconds : Int64

    # Creates an interval from its three parts.
    def initialize(*, @months : Int32 = 0, @days : Int32 = 0, @microseconds : Int64 = 0_i64)
    end

    # Creates an interval with no months or days from *span*, truncated
    # toward zero to whole microseconds. Raises `ArgumentError` if *span*
    # does not fit in 64 bits of microseconds (about 292,000 years).
    def initialize(span : Time::Span)
      @months = 0
      @days = 0
      @microseconds = begin
        span.to_i.to_i64 * 1_000_000 + span.nanoseconds.tdiv(1000)
      rescue OverflowError
        raise ArgumentError.new("#{span} is out of range for an interval")
      end
    end

    # Converts to a `Time::Span`, counting a day as 24 hours. Raises
    # `ArgumentError` if `months` is not zero, since a month has no fixed
    # length.
    def to_span : Time::Span
      raise ArgumentError.new("cannot convert an interval of #{@months} months to Time::Span") unless @months == 0
      # Every interval without months fits: days * 86400 and the
      # microseconds' seconds both stay far below Int64::MAX.
      Time::Span.new(
        seconds: @days.to_i64 * 86_400 + @microseconds.tdiv(1_000_000),
        nanoseconds: @microseconds.remainder(1_000_000) * 1000)
    end

    # Writes the ISO 8601 duration form, e.g. `P1Y2M3DT4H5M6.5S` (`PT0S`
    # for zero). Negative parts carry their own sign.
    def to_s(io : IO) : Nil
      io << 'P'
      years, months = @months.divmod(12)
      years, months = -((-@months) // 12), -((-@months) % 12) if @months < 0
      io << years << 'Y' unless years == 0
      io << months << 'M' unless months == 0
      io << @days << 'D' unless @days == 0
      if @microseconds != 0 || (@months == 0 && @days == 0)
        io << 'T'
        us = @microseconds.abs
        sign = @microseconds < 0 ? "-" : ""
        hours, us = us.divmod(3_600_000_000_i64)
        minutes, us = us.divmod(60_000_000_i64)
        seconds, us = us.divmod(1_000_000_i64)
        io << sign << hours << 'H' unless hours == 0
        io << sign << minutes << 'M' unless minutes == 0
        if seconds != 0 || us != 0 || (hours == 0 && minutes == 0)
          io << sign << seconds
          io << '.' << us.to_s.rjust(6, '0').rstrip('0') unless us == 0
          io << 'S'
        end
      end
    end

    # :ditto:
    def inspect(io : IO) : Nil
      io << "Postgres::Interval(" << self << ')'
    end
  end
end
