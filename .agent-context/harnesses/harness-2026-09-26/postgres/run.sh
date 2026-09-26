#!/usr/bin/env bash
# Builds the Crystal, Go and Rust PostgreSQL benchmarks in release mode,
# loads the fixture, runs every benchmark 3 times per implementation
# (sequentially, never in parallel) and prints a table of medians plus the
# individual runs. Raw output goes to results/.
#
#   ./run.sh            # build + run
#   SKIP_BUILD=1 ./run.sh
#   RUNS=5 ./run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
export PG_URL="${PG_URL:-postgres://postgres@127.0.0.1:5432/crystal_test?sslmode=disable}"
export PATH="/opt/crystal-boot/crystal-1.21.0-1/bin:/usr/local/go/bin:/root/.cargo/bin:$PATH"
RUNS="${RUNS:-3}"
WORKERS="${CRYSTAL_WORKERS:-4}"
OUT="$HERE/results"
mkdir -p "$OUT"

if [[ -z "${SKIP_BUILD:-}" ]]; then
  echo "== building" >&2
  (cd "$REPO" && bin/crystal build --release -o "$HERE/bench_cr" "$HERE/bench.cr")
  (cd "$REPO" && bin/crystal build --release -Dpreview_mt -Dexecution_context -o "$HERE/bench_cr_mt" "$HERE/bench.cr") \
    || echo "!! MT build failed; the crystal-mt row will be missing" >&2
  (cd "$HERE/go" && go build -o bench_go .)
  (cd "$HERE/rs" && cargo build --release --quiet)
fi

echo "== setup.sql" >&2
psql "$PG_URL" -q -v ON_ERROR_STOP=1 -f "$HERE/setup.sql" 2>&1 | grep -v 'does not exist, skipping' >&2 || true

# impl-name -> command
declare -A CMD=(
  [crystal]="$HERE/bench_cr"
  [go]="$HERE/go/bench_go"
  [rust]="$HERE/rs/target/release/bench_rs"
)
IMPLS=(crystal go rust)

: > "$OUT/raw.txt"
run() { # impl bench cmd...
  local impl=$1 bench=$2; shift 2
  for r in $(seq 1 "$RUNS"); do
    line=$("$@" "$bench" | grep '^RESULT') || line="RESULT $bench FAILED"
    echo "$impl $r $line" | tee -a "$OUT/raw.txt" >&2
  done
}

for bench in seq fetch pool; do
  for impl in "${IMPLS[@]}"; do
    run "$impl" "$bench" "${CMD[$impl]}"
  done
  if [[ $bench == pool && -x "$HERE/bench_cr_mt" ]]; then
    run "crystal-mt(${WORKERS}w)" pool env CRYSTAL_WORKERS="$WORKERS" "$HERE/bench_cr_mt"
  fi
  if [[ $bench == pool ]]; then
    # diagnostic: 8 raw Connections through a Channel instead of Pool(T)
    run "crystal-chanpool(diag)" pool_chan "$HERE/bench_cr"
  fi
done

# Table: median of the runs, then every run in brackets.
awk -v runs="$RUNS" '
function val(line, key,   m) { if (match(line, key "=[0-9.]+")) return substr(line, RSTART + length(key) + 1, RLENGTH - length(key) - 1); return "" }
function med(s,   a, n, i, j, t) { n = split(s, a, " "); for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }; return a[int((n + 1) / 2)] }
{
  impl = $1; bench = $4
  if (bench == "seq")   { k["seq mean µs", impl] = k["seq mean µs", impl] " " val($0, "mean_us"); k["seq p50 µs", impl] = k["seq p50 µs", impl] " " val($0, "p50_us"); k["seq p99 µs", impl] = k["seq p99 µs", impl] " " val($0, "p99_us") }
  if (bench == "fetch") { k["fetch ms", impl] = k["fetch ms", impl] " " val($0, "ms_per_fetch"); k["fetch rows/s", impl] = k["fetch rows/s", impl] " " val($0, "rows_per_s") }
  if (bench == "pool" || bench == "pool_chan")  { k["pool ops/s", impl] = k["pool ops/s", impl] " " val($0, "ops_per_s") }
  if (!(impl in seen)) { seen[impl] = 1; order[++ni] = impl }
}
END {
  split("seq mean µs|seq p50 µs|seq p99 µs|fetch ms|fetch rows/s|pool ops/s", rows, "|")
  printf "| metric |"; for (i = 1; i <= ni; i++) printf " %s |", order[i]; printf "\n|---|"; for (i = 1; i <= ni; i++) printf "---:|"; printf "\n"
  for (r = 1; r <= 6; r++) {
    printf "| %s |", rows[r]
    for (i = 1; i <= ni; i++) { s = k[rows[r], order[i]]; if (s == "") printf " — |"; else printf " **%s** (%s) |", med(s), substr(s, 2) }
    printf "\n"
  }
}' "$OUT/raw.txt" | tee "$OUT/table.md"
