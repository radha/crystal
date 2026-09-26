require "../../support/postgres"

private def col(oid : UInt32)
  Postgres::Column.new("c", oid)
end

private def encode(oid : UInt32, value) : {String, Int16}
  io = IO::Memory.new
  format = Postgres::Codec.encode(io, oid, value)
  {io.to_slice.hexstring, format}
end

private def decode(hex : String, oid : UInt32, type : T.class) : T forall T
  Postgres::Codec.decode(hex.hexbytes, col(oid), T)
end

private def bits(text : String) : BitArray
  BitArray.new(text.size).tap { |b| text.each_char_with_index { |ch, i| b[i] = ch == '1' } }
end

# Vectors: `select encode(<type>_send(...), 'hex')` on PostgreSQL 16.
describe "Postgres types (codec)" do
  it "encodes and decodes inet and cidr" do
    encode(Postgres::OID::INET, Postgres::Inet.parse("10.1.2.3/8")).should eq({"020800040a010203", 1_i16})
    encode(Postgres::OID::INET, Postgres::Inet.parse("10.1.2.3")).should eq({"022000040a010203", 1_i16})
    encode(Postgres::OID::CIDR, Postgres::Inet.parse("2001:db8::/32", cidr: true)).should eq({"0320011020010db8000000000000000000000000", 1_i16})
    decode("020800040a010203", Postgres::OID::INET, Postgres::Inet).to_s.should eq("10.1.2.3/8")
    decode("022000040a010203", Postgres::OID::INET, String).should eq("10.1.2.3")
    decode("0320011020010db8000000000000000000000000", Postgres::OID::CIDR, String).should eq("2001:db8::/32")
    decode("022000040a010203", Postgres::OID::INET, Socket::IPAddress).address.should eq("10.1.2.3")
    encode(Postgres::OID::INET, Socket::IPAddress.new("::1", 0)).should eq({"03800010" + "00" * 15 + "01", 1_i16})
    expect_raises(ArgumentError, /prefix 33/) { Postgres::Inet.parse("1.2.3.4/33") }
  end

  it "encodes and decodes mac addresses, timetz, bit strings and money" do
    encode(Postgres::OID::MACADDR, Postgres::MacAddress.parse("08:00:2b:01:02:03")).should eq({"08002b010203", 1_i16})
    decode("08002b0102030405", Postgres::OID::MACADDR8, String).should eq("08:00:2b:01:02:03:04:05")
    tz = Postgres::TimeTz.new(13.hours + 14.minutes + 15.5.seconds, 7200)
    encode(Postgres::OID::TIMETZ, tz).should eq({"0000000b187d38e0ffffe3e0", 1_i16})
    decode("0000000b187d38e0ffffe3e0", Postgres::OID::TIMETZ, Postgres::TimeTz).offset.should eq(7200)
    decode("0000000b187d38e0ffffe3e0", Postgres::OID::TIMETZ, String).should eq("13:14:15.5+02:00")
    encode(Postgres::OID::BIT, bits("10110")).should eq({"00000005b0", 1_i16})
    encode(Postgres::OID::VARBIT, bits("101100111")).should eq({"00000009b380", 1_i16})
    decode("00000009b380", Postgres::OID::VARBIT, BitArray).should eq(bits("101100111"))
    decode("00000009b380", Postgres::OID::VARBIT, String).should eq("101100111")
    encode(Postgres::OID::MONEY, 1234).should eq({"00000000000004d2", 1_i16})
    decode("00000000000004d2", Postgres::OID::MONEY, Int64).should eq(1234)
    expect_raises(Postgres::DecodeError, /money cannot be decoded as String/) { decode("00000000000004d2", Postgres::OID::MONEY, String) }
  end

  it "encodes and decodes ranges" do
    int4range = 3904_u32
    r = Postgres::Range(Int32).new(1, 10)
    encode(int4range, r).should eq({"020000000400000001000000040000000a", 1_i16})
    encode(int4range, 1...10).should eq({"020000000400000001000000040000000a", 1_i16})
    decode("020000000400000001000000040000000a", int4range, Postgres::Range(Int32)).should eq(r)
    decode("020000000400000001000000040000000a", int4range, String).should eq("[1,10)")
    encode(int4range, Postgres::Range(Int32).empty).should eq({"01", 1_i16})
    decode("01", int4range, Postgres::Range(Int32)).empty?.should be_true
    decode("080000000400000006", int4range, Postgres::Range(Int32)).to_s.should eq("(,6)")
    tstzrange = 3910_u32
    from = Time.utc(2026, 1, 1)
    encode(tstzrange, from..).should eq({"12000000080002ea470ae86000", 1_i16})
    decode("12000000080002ea470ae86000", tstzrange, String).should eq(%(["2026-01-01 00:00:00+00",\)))
    r.includes?(9).should be_true
    r.includes?(10).should be_false
    expect_raises(Postgres::EncodeError, /cannot encode String as a int4range bound/) { encode(int4range, "a".."b") }
  end

  it "parses and writes hstore text" do
    text = %("a"=>"1", "b"=>NULL, "q\\"x"=>"y z", "e"=>"")
    Postgres::Codec.decode(text.to_slice, Postgres::Column.new("h", 16385_u32, format: 0_i16), Hash(String, String?))
      .should eq({"a" => "1", "b" => nil, %(q"x) => "y z", "e" => ""})
    expected = %("a"=>"1", "b"=>NULL, "q\\"x"=>"y z")
    encode(16385_u32, {"a" => "1", "b" => nil, %(q"x) => "y z"}).should eq({expected.to_slice.hexstring, 0_i16})
    expect_raises(Postgres::DecodeError, /malformed hstore/) do
      Postgres::Codec.decode(%("a"=>).to_slice, Postgres::Column.new("h", 16385_u32, format: 0_i16), Hash(String, String?))
    end
  end
end

describe "Postgres types (live)" do
  pending_postgres "round-trips the extra built-in types" do
    PostgresSpec.connect do |conn|
      net = Postgres::Inet.parse("192.168.0.0/16", cidr: true)
      conn.query_one("select $1::cidr", net, as: Postgres::Inet).should eq(net)
      conn.query_one("select $1::inet", "fe80::1/64", as: String).should eq("fe80::1/64")
      conn.query_one("select $1::inet[]", [Postgres::Inet.parse("10.0.0.1")], as: Array(Postgres::Inet)).map(&.to_s).should eq(["10.0.0.1"])
      conn.query_one("select '10.0.0.0/8'::cidr", as: String).should eq("10.0.0.0/8")
      mac = Postgres::MacAddress.parse("08-00-2B-01-02-03")
      conn.query_one("select $1::macaddr", mac, as: Postgres::MacAddress).should eq(mac)
      conn.query_one("select '13:14:15.5+02'::timetz", as: Postgres::TimeTz).to_s.should eq("13:14:15.5+02:00")
      conn.query_one("select $1::varbit", bits("1011001"), as: BitArray).should eq(bits("1011001"))
      conn.query_one("select B'101'::bit(3)", as: String).should eq("101")
      conn.query_one("select '12.34'::money", as: Int64).should eq(1234)
      conn.query_one("select $1::money::text", 1234, as: String).should eq("$12.34")
      conn.query_one("select $1::xml", "<a>b</a>", as: String).should eq("<a>b</a>")
    end
  end

  pending_postgres "round-trips ranges of every built-in kind" do
    PostgresSpec.connect do |conn|
      conn.query_one("select $1::int4range", 1..5, as: Postgres::Range(Int32)).to_s.should eq("[1,6)")
      conn.query_one("select $1::int8range", Postgres::Range(Int64).new(nil, 7_i64), as: Postgres::Range(Int64)).to_s.should eq("(,7)")
      num = Postgres::Range(BigDecimal).new(BigDecimal.new("1.5"), BigDecimal.new("2.25"), upper_inclusive: true)
      conn.query_one("select $1::numrange", num, as: Postgres::Range(BigDecimal)).should eq(num)
      t = Time.utc(2026, 9, 26, 12, 0, 0)
      conn.query_one("select $1::tstzrange", t...(t + 1.hour), as: Postgres::Range(Time)).upper.should eq(t + 1.hour)
      conn.query_one("select $1::daterange", Time.utc(2026, 1, 1)..Time.utc(2026, 1, 31), as: String).should eq("[2026-01-01,2026-02-01)")
      conn.query_one("select 'empty'::int4range", as: Postgres::Range(Int32)).empty?.should be_true
      conn.query_one("select int4range(1, 10) @> $1::int4", 5, as: Bool).should be_true
      conn.query_one("select $1::int4range[]", [1..2, 5..6], as: Array(Postgres::Range(Int32))).map(&.to_s).should eq(["[1,3)", "[5,7)"])
    end
  end

  pending_postgres "reads and writes hstore" do
    PostgresSpec.connect do |conn|
      conn.exec("create extension if not exists hstore")
      h = {"a" => "1", "b" => nil, %(we"ird) => "x, y=>z"}
      conn.query_one("select $1::hstore", h, as: Hash(String, String?)).should eq(h)
      conn.query_one("select $1::hstore -> 'a'", h, as: String).should eq("1")
    end
  end
end
