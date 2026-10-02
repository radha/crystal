#!/usr/bin/env bash
# Builds the Crystal, Rust and Go benchmarks, runs them alternately ROUNDS
# times and prints the best (and median) ns/op per cell as a Markdown table.
# Usage: ./run.sh [ROUNDS]   (default 3 rounds; OUT=dir for binaries/results)
# Re-render an existing results file: ./run.sh --table results.txt
set -euo pipefail
cd "$(dirname "$0")"

table() {
  python3 - "$1" << 'EOF'
import sys, collections, statistics
runs = collections.defaultdict(list)
order = []
for line in open(sys.argv[1]):
    lib, data, op, ns = line.split()[:4]
    if (data, op) not in order:
        order.append((data, op))
    runs[(lib, data, op)].append(float(ns))
libs = [l for l in ["crystal", "radix_trie", "qp-trie", "go-radix"] if any(k[0] == l for k in runs)]
best = {k: min(v) for k, v in runs.items()}
med = {k: statistics.median(v) for k, v in runs.items()}
print("Best of all rounds, ns/op (median across rounds in parentheses):\n")
print("| data | op | " + " | ".join(libs) + " | Crystal / best Rust (best) | (median) |")
print("|---|---|" + "---:|" * (len(libs) + 2))
for data, op in order:
    cells = " | ".join(f"{best[(l, data, op)]:.1f} ({med[(l, data, op)]:.1f})" for l in libs)
    rb = min(best[(l, data, op)] for l in ("radix_trie", "qp-trie"))
    rm = min(med[(l, data, op)] for l in ("radix_trie", "qp-trie"))
    print(f"| {data} | {op} | {cells} | {best[('crystal', data, op)] / rb:.2f} | {med[('crystal', data, op)] / rm:.2f} |")
EOF
}

if [ "${1:-}" = "--table" ]; then
  table "$2"
  exit
fi

ROUNDS=${1:-3}
OUT=${OUT:-/tmp/radix_bench}
REPO=$(git rev-parse --show-toplevel)
mkdir -p "$OUT"

"$REPO/bin/crystal" build --release bench.cr -o "$OUT/bench_cr"
cargo build --release -q
cp target/release/radix_bench "$OUT/bench_rs"
BINS=("$OUT/bench_cr" "$OUT/bench_rs")
if command -v go > /dev/null && [ -f go/go.mod ]; then
  (cd go && go build -o "$OUT/bench_go" .)
  BINS+=("$OUT/bench_go")
fi

: > "$OUT/results.txt"
for _ in $(seq "$ROUNDS"); do
  for bin in "${BINS[@]}"; do
    "$bin" >> "$OUT/results.txt"
  done
done
table "$OUT/results.txt"
