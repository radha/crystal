require "spec"
require "postgres"

private def col(oid : UInt32, binary = true)
  Postgres::Column.new("c", oid, format: binary ? 1_i16 : 0_i16)
end

private def encode(oid : UInt32, value) : {String, Int16}
  io = IO::Memory.new
  format = Postgres::Codec.encode(io, oid, value)
  {io.to_slice.hexstring, format}
end

private def decode(hex : String, oid : UInt32, type : T.class) : T forall T
  Postgres::Codec.decode(hex.hexbytes, col(oid), T)
end

# Expected bytes come from the server's own send functions, e.g.
# `select encode(numeric_send(1234.5678), 'hex')` on PostgreSQL 16.
private VECTORS = {
  numeric: [
    {"1234.5678", "000200000000000404d2162e"},
    {"-0.00012", "0002ffff40000005000107d0"},
    {"10000000", "000100010000000003e8"},
    {"0", "0000000000000000"},
  ],
}

describe Postgres::Codec do
  it "encodes and decodes integers by parameter type, range-checked" do
    encode(Postgres::OID::INT4, 5).should eq({"00000005", 1_i16})
    encode(Postgres::OID::INT2, -2).should eq({"fffe", 1_i16})
    encode(Postgres::OID::INT8, 7_i16).should eq({"0000000000000007", 1_i16})
    encode(Postgres::OID::FLOAT8, 3).should eq({"4008000000000000", 1_i16})
    expect_raises(Postgres::EncodeError, /out of range for int2/) { encode(Postgres::OID::INT2, 70_000) }
    expect_raises(Postgres::EncodeError, /cannot encode Int32 as text/) { encode(Postgres::OID::TEXT, 1) }
    decode("fffe", Postgres::OID::INT2, Int64).should eq(-2_i64)
    decode("00000005", Postgres::OID::INT4, Int32).should eq(5)
    expect_raises(Postgres::DecodeError, /int8 cannot be decoded as Int32/) { decode("0000000000000005", Postgres::OID::INT8, Int32) }
  end

  it "encodes floats, sending numeric as exact text" do
    encode(Postgres::OID::FLOAT8, 1.5).should eq({"3ff8000000000000", 1_i16})
    encode(Postgres::OID::NUMERIC, 0.1).should eq({"0.1".to_slice.hexstring, 0_i16})
    encode(Postgres::OID::NUMERIC, Float64::NAN).should eq({"NaN".to_slice.hexstring, 0_i16})
    decode("3ff8000000000000", Postgres::OID::FLOAT8, Float64).should eq(1.5)
    decode("3fc00000", Postgres::OID::FLOAT4, Float64).should eq(1.5)
  end

  it "round-trips numeric against the server's binary form" do
    VECTORS[:numeric].each do |text, hex|
      encode(Postgres::OID::NUMERIC, BigDecimal.new(text)).should eq({hex, 1_i16})
      decode(hex, Postgres::OID::NUMERIC, BigDecimal).should eq(BigDecimal.new(text))
    end
    # numeric_send(12.50): dscale 2 is kept.
    decode("0002000000000002000c1388", Postgres::OID::NUMERIC, BigDecimal).to_s.should eq("12.5")
    decode("0002000000000002000c1388", Postgres::OID::NUMERIC, BigDecimal).scale.should eq(2)
    expect_raises(Postgres::DecodeError, /NaN/) { decode("00000000c0000000", Postgres::OID::NUMERIC, BigDecimal) }
  end

  it "round-trips random decimals" do
    rng = Random.new(42)
    200.times do
      digits = rng.rand(1..40)
      scale = rng.rand(0..digits)
      text = String.build { |s| digits.times { s << rng.rand(10) } }
      text = "#{text[0, digits - scale].presence || "0"}.#{text[digits - scale, scale]}" if scale > 0
      text = "-#{text}" if rng.next_bool
      value = BigDecimal.new(text)
      io = IO::Memory.new
      Postgres::Codec.encode(io, Postgres::OID::NUMERIC, value)
      Postgres::Codec.decode(io.to_slice, col(Postgres::OID::NUMERIC), BigDecimal).should eq(value)
    end
  end

  it "encodes and decodes timestamps, dates and times like the server" do
    t = Time.utc(2026, 9, 26, 12, 34, 56, nanosecond: 789_012_000)
    encode(Postgres::OID::TIMESTAMPTZ, t).should eq({"0002ff60d4470614", 1_i16})
    decode("0002ff60d4470614", Postgres::OID::TIMESTAMPTZ, Time).should eq(t)
    old = Time.utc(1850, 1, 1, nanosecond: 500_000_000)
    encode(Postgres::OID::TIMESTAMP, old).should eq({"ffef2ee5ba18e120", 1_i16})
    decode("ffef2ee5ba18e120", Postgres::OID::TIMESTAMP, Time).should eq(old)
    # A zoned Time encodes its instant.
    encode(Postgres::OID::TIMESTAMPTZ, t.in(Time::Location.fixed(3600))).should eq({"0002ff60d4470614", 1_i16})
    encode(Postgres::OID::DATE, Time.utc(1999, 12, 31, 23, 0, 0)).should eq({"ffffffff", 1_i16})
    decode("ffffffff", Postgres::OID::DATE, Time).should eq(Time.utc(1999, 12, 31))
    decode("0000000b187d38e0", Postgres::OID::TIME, Time::Span).should eq(13.hours + 14.minutes + 15.5.seconds)
    encode(Postgres::OID::TIME, 13.hours + 14.minutes + 15.5.seconds).should eq({"0000000b187d38e0", 1_i16})
    expect_raises(Postgres::DecodeError, /infinity/) { decode("7fffffffffffffff", Postgres::OID::TIMESTAMPTZ, Time) }
  end

  it "encodes and decodes intervals" do
    iv = Postgres::Interval.new(months: 14, days: 3, microseconds: 14_706_500_000_i64)
    encode(Postgres::OID::INTERVAL, iv).should eq({"000000036c9361a0000000030000000e", 1_i16})
    decode("000000036c9361a0000000030000000e", Postgres::OID::INTERVAL, Postgres::Interval).should eq(iv)
    decode("fffffffffff0bdc0ffffffff00000000", Postgres::OID::INTERVAL, Time::Span).should eq(-1.day - 1.second)
    expect_raises(Postgres::DecodeError, /14 months/) { decode("000000036c9361a0000000030000000e", Postgres::OID::INTERVAL, Time::Span) }
    encode(Postgres::OID::INTERVAL, 90.minutes).should eq({"0000000141dd760000000000" + "00000000", 1_i16})
  end

  it "handles strings, json and bytes" do
    encode(Postgres::OID::TEXT, "héllo").should eq({"héllo".to_slice.hexstring, 1_i16})
    encode(Postgres::OID::JSONB, %({"a": 1})).should eq({"017b2261223a20317d", 1_i16})
    decode("017b2261223a20317d", Postgres::OID::JSONB, String).should eq(%({"a": 1}))
    decode("017b2261223a20317d", Postgres::OID::JSONB, JSON::Any)["a"].should eq(1)
    # Types without a binary encoder get the text form for the server to parse.
    encode(869_u32, "10.0.0.1").should eq({"10.0.0.1".to_slice.hexstring, 0_i16})
    encode(Postgres::OID::BYTEA, Bytes[1, 2, 255]).should eq({"0102ff", 1_i16})
    decode("0102ff", Postgres::OID::BYTEA, Bytes).should eq(Bytes[1, 2, 255])
    Postgres::Codec.decode("{1,2}".to_slice, col(1007_u32, binary: false), String).should eq("{1,2}")
    expect_raises(Postgres::DecodeError, /int4 cannot be decoded as String/) { decode("00000001", Postgres::OID::INT4, String) }
  end

  it "handles uuids and bools" do
    uuid = UUID.new("7c222906-5c15-4991-b5d5-87a75f09cda2")
    encode(Postgres::OID::UUID, uuid).should eq({"7c2229065c154991b5d587a75f09cda2", 1_i16})
    decode("7c2229065c154991b5d587a75f09cda2", Postgres::OID::UUID, UUID).should eq(uuid)
    encode(Postgres::OID::BOOL, true).should eq({"01", 1_i16})
    decode("00", Postgres::OID::BOOL, Bool).should be_false
  end
end

describe Postgres::Interval do
  it "formats as ISO 8601" do
    Postgres::Interval.new(months: 14, days: 3, microseconds: 14_706_500_000_i64).to_s.should eq("P1Y2M3DT4H5M6.5S")
    Postgres::Interval.new.to_s.should eq("PT0S")
    Postgres::Interval.new(microseconds: -1_000_000_i64).to_s.should eq("PT-1S")
    Postgres::Interval.new(months: -13).to_s.should eq("P-1Y-1M")
  end

  it "converts to and from Time::Span" do
    Postgres::Interval.new(90.minutes).to_span.should eq(90.minutes)
    Postgres::Interval.new(days: 2, microseconds: 1).to_span.should eq(2.days + 1.microsecond)
    expect_raises(ArgumentError, /months/) { Postgres::Interval.new(months: 1).to_span }
  end
end

describe Postgres::StatementCache do
  it "evicts the least recently used statement and queues its close" do
    cache = Postgres::StatementCache.new(2)
    s = ->(name : String) { Postgres::PreparedStatement.new(name, [] of UInt32, [] of Postgres::Column) }
    cache.add("a", s.call(cache.next_name))
    cache.add("b", s.call(cache.next_name))
    cache["a"].not_nil!.name.should eq("s1") # a is now most recent
    cache.add("c", s.call(cache.next_name))
    cache["b"].should be_nil
    cache.closes.should eq(["s2"])
    cache.size.should eq(2)
    cache.clear
    cache.closes.should eq(["s2", "s1", "s3"])
  end

  it "asks for binary results only for types it decodes" do
    all_binary = Postgres::PreparedStatement.new("", [] of UInt32, [Postgres::Column.new("a", Postgres::OID::INT4, format: 0_i16)])
    all_binary.result_formats.should eq([1_i16])
    mixed = Postgres::PreparedStatement.new("", [] of UInt32, [Postgres::Column.new("a", Postgres::OID::INT4), Postgres::Column.new("b", 1007_u32)])
    mixed.result_formats.should eq([1_i16, 0_i16])
    mixed.columns.map(&.binary?).should eq([true, false])
  end
end

describe Postgres::ExecResult do
  it "reads the row count from the command tag" do
    Postgres::ExecResult.from_tag("INSERT 0 5").rows_affected.should eq(5)
    Postgres::ExecResult.from_tag("UPDATE 3").command.should eq("UPDATE")
    Postgres::ExecResult.from_tag("CREATE TABLE").should eq(Postgres::ExecResult.new("CREATE TABLE", 0))
  end
end
