require "../../support/postgres"

# Regressions for the second codec/config/auth review: exact span
# arithmetic, composite field text forms, out-of-range values raising
# `DecodeError`, malformed-input hardening and libpq parity.

private def col(oid : UInt32, binary = true)
  Postgres::Column.new("c", oid, format: binary ? 1_i16 : 0_i16)
end

private def be(*values : Int) : Bytes
  io = IO::Memory.new
  values.each { |v| io.write_bytes(v, IO::ByteFormat::BigEndian) }
  io.to_slice
end

private def encode(oid : UInt32, value) : {String, Int16}
  io = IO::Memory.new
  format = Postgres::Codec.encode(io, oid, value)
  {io.to_s, format}
end

private def encode_hex(oid : UInt32, value) : String
  io = IO::Memory.new
  Postgres::Codec.encode(io, oid, value)
  io.to_slice.hexstring
end

private enum ReviewMood
  Happy
  OnHold
end

# Microseconds since 2000-01-01 of 10000-01-01 00:00:00 (one day past
# the last day Crystal's `Time` holds).
private US_10000 = (Time.utc(9999, 12, 31).to_unix - Postgres::Codec::PG_EPOCH_UNIX + 86_400) * 1_000_000

private EMPTY_ENV = {} of String => String

private def with_passfile(content : String, &)
  path = File.tempname("pgpass")
  File.write(path, content)
  File.chmod(path, 0o600)
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

describe "Postgres review regressions" do
  describe "exact span arithmetic" do
    it "converts a Time::Span to an interval exactly" do
      [1, 365, 3000, 36_500, 100_000].each do |days|
        [1, 7, 999].each do |us|
          span = Time::Span.new(days: days, nanoseconds: us * 1000)
          Postgres::Interval.new(span).microseconds.should eq(days.to_i64 * 86_400_000_000 + us)
        end
      end
    end

    it "truncates a span toward zero" do
      Postgres::Interval.new(Time::Span.new(nanoseconds: -1)).microseconds.should eq(0)
      Postgres::Interval.new(Time::Span.new(nanoseconds: -1500)).microseconds.should eq(-1)
      Postgres::Interval.new(Time::Span.new(nanoseconds: 1999)).microseconds.should eq(1)
    end

    it "rejects a span beyond 64 bits of microseconds" do
      expect_raises(ArgumentError, /out of range/) { Postgres::Interval.new(Time::Span::MAX) }
      expect_raises(Postgres::EncodeError, /out of range/) { encode(Postgres::OID::INTERVAL, Time::Span::MAX) }
    end

    it "converts any month-free interval to a Time::Span without overflow" do
      Postgres::Interval.new(microseconds: Int64::MAX).to_span.should eq(Time::Span.new(seconds: Int64::MAX // 1_000_000, nanoseconds: (Int64::MAX % 1_000_000) * 1000))
      Postgres::Interval.new(days: -1, microseconds: 7_200_000_000_i64).to_span.should eq(-22.hours)
      Postgres::Interval.new(days: Int32::MAX, microseconds: Int64::MIN).to_span.should eq(
        Time::Span.new(seconds: Int32::MAX.to_i64 * 86_400 + Int64::MIN.tdiv(1_000_000), nanoseconds: Int64::MIN.remainder(1_000_000) * 1000))
      Postgres::Codec.decode(be(Int64::MAX - 1, 0_i32, 0_i32), col(Postgres::OID::INTERVAL), Time::Span).to_i.should eq((Int64::MAX - 1) // 1_000_000)
    end

    it "encodes time and timetz exactly" do
      span = Time::Span.new(hours: 23, minutes: 59, seconds: 59, nanoseconds: 999_999_999)
      encode_hex(Postgres::OID::TIME, span).should eq(be(86_399_999_999_i64).hexstring)
      encode_hex(Postgres::OID::TIMETZ, Postgres::TimeTz.new(span, 3600)).should eq(be(86_399_999_999_i64, -3600_i32).hexstring)
      # A timetz outside a day used to be sent through Float64 unchecked.
      expect_raises(Postgres::EncodeError, /time of day/) { encode_hex(Postgres::OID::TIMETZ, Postgres::TimeTz.new(Time::Span.new(days: 200_000_000, nanoseconds: 1000))) }
    end
  end

  describe "composite field text" do
    it "writes each field in a form PostgreSQL parses" do
      at = Time.utc(2024, 1, 2, 3, 4, 5, nanosecond: 600_000_000)
      tuple = {26.hours + 1.microsecond, Bytes[1, 0xab], ReviewMood::OnHold, true, false, at,
               Postgres::Interval.new(months: 14, days: -3, microseconds: -14_706_500_000_i64), [1, nil], {1, "a"}}
      encode(Postgres::OID::RECORD, tuple).should eq({
        %q[("26:00:00.000001","\\x01ab","on_hold","t","f","2024-01-02 03:04:05.600000+00","14 mons -3 days -4:05:06.5","{""1"",NULL}","(""1"",""a"")")],
        0_i16,
      })
    end

    it "rejects a field without a text form" do
      expect_raises(Postgres::EncodeError, /Postgres::Range/) do
        encode(Postgres::OID::RECORD, {Postgres::Range(Int32).new(1, 2)})
      end
    end

    pending_postgres "round-trips interval, bytea, enum, bool and timestamptz fields" do
      PostgresSpec.connect do |conn|
        conn.exec("set timezone = 'UTC'")
        conn.exec("drop type if exists spec_review_row cascade; drop type if exists spec_review_mood cascade")
        conn.exec("create type spec_review_mood as enum ('happy', 'on_hold')")
        conn.exec("create type spec_review_row as (iv interval, iv2 interval, b bytea, m spec_review_mood, ok bool, at timestamptz, t time, ints int[])")
        begin
          at = Time.utc(2024, 1, 2, 3, 4, 5, nanosecond: 123_456_000)
          iv = Postgres::Interval.new(months: -14, days: 3, microseconds: -14_706_500_000_i64)
          row = conn.query_one("select $1::spec_review_row::text", {26.hours + 1.microsecond, iv, Bytes[0, 0x5c, 0x22, 0xff], ReviewMood::OnHold, true, at, 90.minutes, [1, 2]}, as: String)
          row.should eq(%q[(26:00:00.000001,"-1 years -2 mons +3 days -04:05:06.5","\\x005c22ff",on_hold,t,"2024-01-02 03:04:05.123456+00",01:30:00,"{1,2}")])
          fields = conn.query_one("select (r).iv, (r).iv2, (r).b, (r).m::text, (r).ok, (r).at, (r).t from (select $1::spec_review_row as r) s",
            {-(26.hours + 1.microsecond), iv, Bytes[0, 0x5c, 0x22, 0xff], ReviewMood::OnHold, false, at, 90.minutes, nil},
            as: {Time::Span, Postgres::Interval, Bytes, String, Bool, Time, Time::Span})
          fields.should eq({-(26.hours + 1.microsecond), iv, Bytes[0, 0x5c, 0x22, 0xff], "on_hold", false, at, 90.minutes})
        ensure
          conn.exec("drop type if exists spec_review_row cascade; drop type if exists spec_review_mood cascade")
        end
      end
    end
  end

  describe "values outside Crystal's range" do
    it "raises DecodeError for timestamps and dates past Time's range" do
      {Postgres::OID::TIMESTAMP, Postgres::OID::TIMESTAMPTZ}.each do |oid|
        expect_raises(Postgres::DecodeError, /10000-01-01 00:00:00/) { Postgres::Codec.decode(be(US_10000), col(oid), Time) }
        expect_raises(Postgres::DecodeError, /outside the range/) { Postgres::Codec.decode(be(Int64::MAX - 1), col(oid), Time) }
      end
      expect_raises(Postgres::DecodeError, /0044-03-15 BC/) { Postgres::Codec.decode(be(-746_117_i32), col(Postgres::OID::DATE), Time) }
      expect_raises(Postgres::DecodeError, /outside the range/) { Postgres::Codec.decode(be(Int32::MAX - 1), col(Postgres::OID::DATE), Time) }
    end

    it "raises DecodeError for a malformed time or timetz" do
      expect_raises(Postgres::DecodeError, /time of day/) { Postgres::Codec.decode(be(Int64::MAX - 1), col(Postgres::OID::TIME), Time::Span) }
      expect_raises(Postgres::DecodeError, /time of day/) { Postgres::Codec.decode(be(-1_i64), col(Postgres::OID::TIME), Time::Span) }
      expect_raises(Postgres::DecodeError, /time of day/) { Postgres::Codec.decode(be(Int64::MAX - 1, 0_i32), col(Postgres::OID::TIMETZ), Postgres::TimeTz) }
      Postgres::Codec.decode(be(86_400_000_000_i64), col(Postgres::OID::TIME), Time::Span).should eq(24.hours)
    end

    it "raises DecodeError for JSON Crystal cannot represent" do
      expect_raises(Postgres::DecodeError, /JSON::Any/) { Postgres::Codec.decode("1e400".to_slice, col(Postgres::OID::JSON), JSON::Any) }
      expect_raises(Postgres::DecodeError, /JSON::Any/) { Postgres::Codec.decode(Bytes[1] + "18446744073709551616".to_slice, col(Postgres::OID::JSONB), JSON::Any) }
      expect_raises(Postgres::DecodeError, /JSON::Any/) { Postgres::Codec.decode("{".to_slice, col(Postgres::OID::JSON), JSON::Any) }
    end

    it "renders range bounds past Time's range as PostgreSQL does" do
      tsrange = 3908_u32
      tstzrange = 3910_u32
      daterange = 3912_u32
      text = ->(oid : UInt32, bytes : Bytes) { Postgres::Codec.decode(bytes, col(oid), String) }
      text.call(tsrange, be(0x02_u8, 8_i32, -64_464_508_800_000_000_i64, 8_i32, US_10000 + 3_723_500_000))
        .should eq("[\"0044-03-15 00:00:00 BC\",\"10000-01-01 01:02:03.5\")")
      text.call(tstzrange, be(0x08_u8 | 0x04_u8, 8_i32, -63_113_904_000_000_000_i64)).should eq("(,\"0001-01-01 00:00:00+00 BC\"]")
      text.call(tsrange, be(0x02_u8, 8_i32, Int64::MIN, 8_i32, Int64::MAX)).should eq("[-infinity,infinity)")
      text.call(daterange, be(0x02_u8, 4_i32, -746_117_i32, 4_i32, Int32::MAX)).should eq("[\"0044-03-15 BC\",infinity)")
    end

    pending_postgres "matches the server for out-of-range values" do
      PostgresSpec.connect do |conn|
        conn.exec("set timezone = 'UTC'")
        expect_raises(Postgres::DecodeError) { conn.query_one("select '10000-01-01'::timestamp", as: Time) }
        expect_raises(Postgres::DecodeError) { conn.query_one("select '0001-12-31 BC'::timestamptz", as: Time) }
        expect_raises(Postgres::DecodeError) { conn.query_one("select '0044-03-15 BC'::date", as: Time) }
        expect_raises(Postgres::DecodeError) { conn.query_one("select '1e400'::json", as: JSON::Any) }
        expect_raises(Postgres::DecodeError) { conn.query_one("select '18446744073709551616'::jsonb", as: JSON::Any) }
        conn.query_one("select interval '2000000000 hours'", as: Time::Span).should eq(2_000_000_000.hours)
        {
          "tstzrange('-infinity', '2024-01-01')",
          "tsrange('0044-03-15 BC', '10000-01-01 01:02:03.5')",
          "tstzrange('0044-03-15 12:00 BC', '2024-01-01')",
          "tsrange('2024-01-01 01:02:03.5', '2025-01-01')",
          "tstzrange('2024-01-01 01:02:03.25', 'infinity', '[]')",
          "daterange('0044-03-15 BC', 'infinity')",
          "daterange('-infinity', '10000-01-01')",
        }.each do |expr|
          conn.query_one("select #{expr}", as: String).should eq(conn.query_one("select #{expr}::text", as: String))
        end
        conn.query_one("select 1", as: Int32).should eq(1)
      end
    end
  end

  describe "text forms" do
    it "renders timestamp range bounds without trailing zeros" do
      bytes = be(0x02_u8, 8_i32, 757_386_123_500_000_i64, 8_i32, 757_386_123_000_000_i64 + 1)
      Postgres::Codec.decode(bytes, col(3908_u32), String).should eq("[\"2024-01-01 01:02:03.5\",\"2024-01-01 01:02:03.000001\")")
    end

    it "keeps timetz offset seconds" do
      Postgres::TimeTz.new(13.hours + 14.minutes + 15.seconds, 5 * 3600 + 30 * 60 + 15).to_s.should eq("13:14:15+05:30:15")
      Postgres::TimeTz.new(13.hours, -(3 * 3600 + 30 * 60)).to_s.should eq("13:00:00-03:30")
    end

    pending_postgres "reads timetz with offset seconds like the server" do
      PostgresSpec.connect do |conn|
        conn.query_one("select '13:14:15+05:30:15'::timetz", as: String).should eq("13:14:15+05:30:15")
        tz = conn.query_one("select '13:14:15+05:30:15'::timetz", as: Postgres::TimeTz)
        conn.query_one("select $1::timetz::text", tz.to_s, as: String).should eq("13:14:15+05:30:15")
      end
    end
  end

  describe "malformed input" do
    it "rejects hstore trailing backslashes and garbage" do
      hstore = col(99_999_u32, binary: false)
      expect_raises(Postgres::DecodeError, /unterminated/) { Postgres::Codec.decode(%("a\\).to_slice, hstore, Hash(String, String?)) }
      expect_raises(Postgres::DecodeError, /unexpected/) { Postgres::Codec.decode(%("a"=>"b" x).to_slice, hstore, Hash(String, String?)) }
      Postgres::Codec.decode(%("a"=>"b\\\\" ).to_slice, hstore, Hash(String, String?)).should eq({"a" => "b\\"})
    end

    it "rejects sizes that would overflow Int32 arithmetic" do
      max = Int32::MAX
      expect_raises(Postgres::DecodeError, /truncated array/) do
        Postgres::Codec.decode(be(1_i32, 0_i32, 23_i32, 1_i32, 1_i32, max), col(1007_u32), Array(Int32))
      end
      expect_raises(Postgres::DecodeError, /truncated array/) do
        Postgres::Codec.decode(be(1_i32, 0_i32, 23_i32, max, 1_i32, 0_i32), col(1007_u32), Array(Int32))
      end
      expect_raises(Postgres::DecodeError, /truncated array/) do
        Postgres::Codec.decode(be(2_i32, 0_i32, 23_i32, 65_536_i32, 1_i32, 65_536_i32, 1_i32), col(1007_u32), Array(Array(Int32)))
      end
      expect_raises(Postgres::DecodeError, /truncated bit string/) do
        Postgres::Codec.decode(be(max), col(Postgres::OID::VARBIT), BitArray)
      end
      expect_raises(Postgres::DecodeError, /truncated range/) do
        Postgres::Codec.decode(be(0x02_u8, max), col(3904_u32), Postgres::Range(Int32))
      end
      expect_raises(Postgres::DecodeError, /truncated record/) do
        Postgres::Codec.decode(be(1_i32, 23_i32, max), col(Postgres::OID::RECORD), Tuple(Int32))
      end
    end

    it "rejects numeric digits and signs PostgreSQL never sends" do
      numeric = col(Postgres::OID::NUMERIC)
      expect_raises(Postgres::DecodeError, /digit/) { Postgres::Codec.decode(be(1_i16, 0_i16, 0_u16, 0_i16, 10_000_i16), numeric, BigDecimal) }
      expect_raises(Postgres::DecodeError, /digit/) { Postgres::Codec.decode(be(1_i16, 0_i16, 0_u16, 0_i16, -1_i16), numeric, BigDecimal) }
      expect_raises(Postgres::DecodeError, /sign/) { Postgres::Codec.decode(be(1_i16, 0_i16, 0x1234_u16, 0_i16, 1_i16), numeric, BigDecimal) }
      Postgres::Codec.decode(be(1_i16, 0_i16, 0x4000_u16, 0_i16, 9999_i16), numeric, BigDecimal).should eq(BigDecimal.new(-9999))
    end
  end

  describe "protocol messages" do
    it "reads a ParameterDescription of more than 32767 parameters" do
      body = IO::Memory.new
      body.write_bytes(40_000_u16, IO::ByteFormat::BigEndian)
      40_000.times { body.write_bytes(23_u32, IO::ByteFormat::BigEndian) }
      message = Postgres::Messages::ParameterDescription.from_slice(body.to_slice)
      message.oids.size.should eq(40_000)
    end
  end

  describe "config" do
    it "matches a non-default socket directory by its path in the password file" do
      with_passfile("/opt/pgsock:5432:*:*:sockpw\nlocalhost:5432:*:*:localpw\n") do |path|
        env = {"PGPASSFILE" => path}
        Postgres::Config.parse("postgres:///x?host=/opt/pgsock", env: env).password.should eq("sockpw")
        Postgres::Config.parse("postgres:///x?host=/tmp", env: env).password.should eq("localpw")
        Postgres::Config.parse("postgres:///x?host=/var/run/postgresql", env: env).password.should eq("localpw")
        Postgres::Config.parse("postgres:///x?host=/srv/other", env: env).password.should be_nil
      end
    end

    it "percent-decodes a bracketed IPv6 host" do
      config = Postgres::Config.parse("postgres://[::1]:5433,[fe80::1%25eth0]:5434/db", env: EMPTY_ENV)
      config.hosts.map(&.host).should eq(["::1", "fe80::1%eth0"])
    end

    it "treats a zero or negative connect_timeout as no timeout" do
      Postgres::Config.parse("postgres://h/d?connect_timeout=0", env: EMPTY_ENV).connect_timeout.should be_nil
      Postgres::Config.parse(env: {"PGCONNECT_TIMEOUT" => "-5"}).connect_timeout.should be_nil
      Postgres::Config.parse(env: EMPTY_ENV, connect_timeout: Time::Span.zero).connect_timeout.should be_nil
      Postgres::Config.parse("postgres://h/d?connect_timeout=0", env: EMPTY_ENV, connect_timeout: 3.seconds).connect_timeout.should eq(3.seconds)
      Postgres::Config.parse(env: EMPTY_ENV).connect_timeout.should eq(10.seconds)
    end
  end

  describe "SCRAM" do
    it "rejects a mandatory extension in server-first-message" do
      scram = Postgres::Auth::Scram.new("pencil", client_nonce: "abc")
      expect_raises(Postgres::AuthenticationError, /mandatory extension/) do
        scram.client_final_message("m=foo,r=abcXYZ,s=QSXCR+Q6sek8bf92,i=4096")
      end
    end
  end
end
