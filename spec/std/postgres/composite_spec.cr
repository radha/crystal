require "../../support/postgres"

private def with_types(conn, &)
  conn.exec("drop type if exists spec_pair cascade; drop domain if exists spec_posint cascade; drop domain if exists spec_email cascade")
  conn.exec("create domain spec_posint as int4 check (value > 0)")
  conn.exec("create domain spec_email as text check (value like '%@%')")
  conn.exec("create type spec_pair as (n spec_posint, label text, at timestamptz)")
  begin
    yield
  ensure
    conn.exec("drop type if exists spec_pair cascade; drop domain if exists spec_posint cascade; drop domain if exists spec_email cascade")
  end
end

describe "Postgres user-defined types" do
  pending_postgres "treats domains as their base type, in parameters, columns and arrays" do
    PostgresSpec.connect do |conn|
      with_types(conn) do
        conn.query_one("select $1::spec_posint", 7, as: Int32).should eq(7)
        conn.query_one("select $1::spec_email", "a@b", as: String).should eq("a@b")
        expect_raises(Postgres::QueryError, /violates check constraint/) { conn.query_one("select $1::spec_posint", -1, as: Int32) }
        conn.query_one("select array[1, 2]::spec_posint[]", as: Array(Int32)).should eq([1, 2])
        conn.query_one("select $1::spec_posint[]", [3, 4], as: Array(Int32)).should eq([3, 4])
        conn.exec("create temp table spec_dom (id spec_posint, mail spec_email)")
        conn.exec("insert into spec_dom values ($1, $2)", 5, "x@y")
        conn.query_one("select id, mail from spec_dom", as: {Int32, String}).should eq({5, "x@y"})
      end
    end
  end

  pending_postgres "decodes composites and anonymous rows as tuples" do
    PostgresSpec.connect do |conn|
      with_types(conn) do
        t = Time.utc(2026, 9, 26, 1, 2, 3)
        conn.query_one("select row(1, 'a', null::int8)", as: {Int32, String, Int64?}).should eq({1, "a", nil})
        conn.query_one("select ($1::int4, $2::text, null)::spec_pair", 2, "b", as: {Int32, String, Time?}).should eq({2, "b", nil})
        conn.query_one("select $1::spec_pair", {3, "c d, \"q\"", t}, as: {Int32, String, Time}).should eq({3, "c d, \"q\"", t})
        conn.query_one("select $1::spec_pair", {4, nil, nil}, as: {Int32, String?, Time?}).should eq({4, nil, nil})
        rows = conn.query_one("select array[(1,'x',null)::spec_pair, (2,'y',null)::spec_pair]", as: Array({Int32, String, Time?}))
        rows.should eq([{1, "x", nil}, {2, "y", nil}])
        expect_raises(Postgres::DecodeError, /record of 3 fields cannot be decoded as Tuple\(Int32, String\)/) do
          conn.query_one("select (1, 'x', null)::spec_pair", as: {Int32, String})
        end
        # A composite as a struct field.
        conn.exec("create temp table spec_comp (id int, p spec_pair)")
        conn.exec("insert into spec_comp values (1, $1)", {9, "z", t})
        conn.query_one("select id, p from spec_comp", as: {Int32, {Int32, String, Time}}).should eq({1, {9, "z", t}})
      end
    end
  end

  pending_postgres "introspects types inside a pipeline too" do
    PostgresSpec.connect do |conn|
      with_types(conn) do
        a = nil
        b = nil
        conn.pipeline do |p|
          a = p.query_one("select $1::spec_posint", 11, as: Int32)
          b = p.query_one("select (1,'k',null)::spec_pair", as: {Int32, String, Time?})
        end
        a.not_nil!.value.should eq(11)
        b.not_nil!.value.should eq({1, "k", nil})
      end
    end
  end
end
