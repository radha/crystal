require "postgres"
conn = Postgres::Connection.new("postgres://postgres@127.0.0.1/crystal_test?sslmode=disable")
conn.exec("drop table if exists bench_copy; create unlogged table bench_copy (id int8, name text, score float8, at timestamptz)")
t = Time.utc
n = 1_000_000
3.times do
  conn.exec("truncate bench_copy")
  start = Time.instant
  conn.copy_rows("bench_copy", {"id", "name", "score", "at"}) do |copy|
    n.times { |i| copy.row(i.to_i64, "name-#{i}", i * 0.5, t) }
  end
  el = (Time.instant - start).total_seconds
  printf("copy_rows 1M: %.2f s (%.0f rows/s)\n", el, n / el)
end
start = Time.instant
rows = conn.copy_to("copy bench_copy to stdout (format binary)", File.open(File::NULL, "w"))
el = (Time.instant - start).total_seconds
printf("copy_to binary 1M: %.2f s (%.0f rows/s)\n", el, rows / el)
conn.exec("drop table bench_copy")
