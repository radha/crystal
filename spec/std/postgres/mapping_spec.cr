require "../../support/postgres"

private enum Mood
  Happy
  OnHold
  VerySad
end

private enum Level
  Low    = 1
  Medium = 2
  High   = 3
end

private struct Cents
  getter value : Int64

  def initialize(@value : Int64)
  end

  def to_pg : Int64
    @value
  end
end

private module CentsConverter
  def self.from_pg(row : Postgres::RowReader, index : Int32) : Cents?
    row.null?(index) ? nil : Cents.new(row.read(index, Int64))
  end
end

private module UpcaseConverter
  def self.from_pg(row : Postgres::RowReader, index : Int32) : String
    row.read(index, String).upcase
  end
end

private struct Mapped
  include Postgres::Serializable
  getter mood : Mood
  getter level : Level
  @[Postgres::Field(converter: CentsConverter)]
  getter price : Cents?
  @[Postgres::Field(key: "nick", converter: UpcaseConverter)]
  getter nickname : String
end

describe "Postgres mapping" do
  pending_postgres "maps PostgreSQL enums and integer columns onto Crystal enums" do
    PostgresSpec.connect do |conn|
      conn.exec("drop type if exists spec_mood cascade")
      conn.exec("create type spec_mood as enum ('happy', 'on_hold', 'very_sad')")
      begin
        conn.query_one("select 'on_hold'::spec_mood", as: Mood).should eq(Mood::OnHold)
        conn.query_one("select $1::spec_mood", Mood::VerySad, as: Mood).should eq(Mood::VerySad)
        conn.query_one("select $1::spec_mood::text", Mood::OnHold, as: String).should eq("on_hold")
        conn.query_one("select 'Happy'::text", as: Mood).should eq(Mood::Happy)
        conn.query_one("select 2::int4", as: Level).should eq(Level::Medium)
        conn.query_one("select $1::int8", Level::High, as: Int64).should eq(3)
        conn.query_one("select null::spec_mood", as: Mood?).should be_nil
        conn.query_one("select array['happy', 'very_sad']::spec_mood[]::text", as: String).should eq("{happy,very_sad}")
        expect_raises(Postgres::DecodeError, /"grumpy" is not a member of Mood/) { conn.query_one("select 'grumpy'::text", as: Mood) }
        expect_raises(Postgres::DecodeError, /9 is not a value of Level/) { conn.query_one("select 9", as: Level) }
      ensure
        conn.exec("drop type if exists spec_mood cascade")
      end
    end
  end

  pending_postgres "decodes rows as tuples everywhere" do
    PostgresSpec.connect do |conn|
      conn.query_all("select g, 'n' || g from generate_series(1, 3) g", as: {Int32, String})
        .should eq([{1, "n1"}, {2, "n2"}, {3, "n3"}])
      conn.query_one("select 1::int8, null::text, array[1.5]::float8[]", as: {Int64, String?, Array(Float64)})
        .should eq({1_i64, nil, [1.5]})
      conn.query_one?("select 1, 2 where false", as: {Int32, Int32}).should be_nil
      seen = [] of {Int32, Bool}
      conn.query_each("select g, g % 2 = 0 from generate_series(1, 2) g", as: {Int32, Bool}) { |t| seen << t }
      seen.should eq([{1, false}, {2, true}])
      expect_raises(Postgres::DecodeError, /reads 2 columns, but the result has 3/) { conn.query_one("select 1, 2, 3", as: {Int32, Int32}) }
      f = nil
      conn.pipeline { |p| f = p.query_all("select 1, 'a'", as: {Int32, String}) }
      f.not_nil!.value.should eq([{1, "a"}])
    end
    db = Postgres::Client.new(PostgresSpec::URL, pool_size: 1)
    begin
      db.query_one("select 7, 'x'", as: {Int32, String}).should eq({7, "x"})
    ensure
      db.close
    end
  end

  pending_postgres "applies converters and to_pg" do
    PostgresSpec.connect do |conn|
      row = conn.query_one("select 'happy'::text as mood, 3 as level, $1::int8 as price, 'ann' as nick", Cents.new(250), as: Mapped)
      row.mood.should eq(Mood::Happy)
      row.level.should eq(Level::High)
      row.price.try(&.value).should eq(250)
      row.nickname.should eq("ANN")
      conn.query_one("select 'on_hold' as mood, 1 as level, null::int8 as price, 'b' as nick", as: Mapped).price.should be_nil
      expect_raises(Postgres::EncodeError, /cannot encode Time::Location as int4/) { conn.query_one("select $1::int4", Time::Location::UTC, as: Int32) }
    end
  end
end

describe "Postgres mapping with file-private types" do
  pending_postgres "reads tuples of private enums" do
    PostgresSpec.connect do |conn|
      conn.query_one("select 'happy'::text, 2", as: {Mood, Level}).should eq({Mood::Happy, Level::Medium})
      conn.query_all("select 'on_hold'::text, null::int4", as: {Mood, Level?}).should eq([{Mood::OnHold, nil}])
    end
  end
end
