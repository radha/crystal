-- Benchmark fixture: 10 000 rows of (int8, text, float8, timestamptz, bool).
DROP TABLE IF EXISTS bench_rows;
CREATE TABLE bench_rows (
  id    int8        NOT NULL,
  name  text        NOT NULL,
  score float8      NOT NULL,
  at    timestamptz NOT NULL,
  ok    bool        NOT NULL
);
INSERT INTO bench_rows (id, name, score, at, ok)
SELECT g,
       'name-' || g || '-' || md5(g::text),
       g * 1.5 + 0.25,
       timestamptz '2026-01-01 00:00:00+00' + g * interval '1 minute',
       g % 2 = 0
FROM generate_series(1, 10000) AS g;
ANALYZE bench_rows;
