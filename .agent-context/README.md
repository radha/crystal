# Agent context: start here

Working notes for this fork, committed so any new session (cloud or
workstation) starts from where the last one stopped. None of this is part of
the Crystal distribution. Last updated 2026-09-26 (end of the cloud session
that finished the Postgres track and merged it to fork `master`).

## Where things stand

- **Goal:** a batteries-included stdlib (no shards for everyday needs; no
  RPC over HTTP; upstream acceptance last; runtime fixes stay fork-only).
  Roadmap: `notes/batteries-roadmap-2026-09-17.md`.
- **Shipped** (all on fork `master`): `require "binary"` (varints, frames,
  bit IO, `Binary::Format`), `require "heap"`, `require "redis"` (client,
  pipelines, pub/sub, transactions, scripts, cluster, pool),
  `require "pool"` (generic `Pool(T)`), and **`require "postgres"`,
  feature complete**: see `docs/superpowers/specs/2026-09-26-postgres-client-design.md`
  (§1–14 design, §15–17 what was built and why, per round).
- **SortedMap / SortedSet** (`require "sorted_map"`, `"sorted_set"`, plus
  `sorted_map/json` etc.): a B-tree with split/join `delete_range`, at or
  under 1.22× Rust `BTreeMap` nearly everywhere. Design:
  `docs/superpowers/specs/2026-09-26-sorted-map-design.md`. Bench:
  `harnesses/harness-2026-09-26/sorted_map/`.
- **LRUCache / SyncLRUCache** (`require "lru_cache"`): count or weight
  bound, TTL, eviction callback, single-flight fetch. Writes beat Rust's
  `lru`, reads 1.2-1.6×. Bench: `harnesses/harness-2026-09-26/lru_cache/`.
- Both are merged to fork `master`.
- **Runtime fixes on the fork** (found through the Postgres benchmarks):
  lazy event-loop timer re-arm, allocation-free `Pool(T)` checkout, and the
  `Parallel` scheduler waking parked threads after the event loop readies
  several fibers.
- **Tier 5 leftovers** (2026-10-02, PR from `claude/vigilant-brown-24w3lc`):
  `require "rapidhash"`, `"bloom_filter"`, `"hyper_log_log"`,
  `"count_min_sketch"`, `"disjoint_set"`, `"radix_tree"`. Benches in
  `harnesses/harness-2026-10-02/`.
- **Next up** (user to choose): Tier 6 fillers (TOML, CLI subcommands),
  Tier 2 serializer → Tier 4 RPC, or exercising the Postgres client in a
  real app first.

## Resuming

### In a Claude Code cloud session

Nothing to do: `.claude/settings.json` registers
`.claude/hooks/session-start.sh`, which runs
`setup/provision-linux.sh` in cloud sessions only. It installs the Crystal
1.21.0 bootstrap compiler, the GMP link, a PostgreSQL 16 test cluster with
every auth role (trust, cleartext, md5, SCRAM, TLS) plus a streaming standby
on 5433, and Redis, then exports the spec environment (`PATH`,
`POSTGRES_*_URL`) into the session. First run ~100 s, later runs <1 s. If a
container restarts mid-session (processes die, files stay), run
`eval "$(.agent-context/setup/provision-linux.sh)"`.

The container's LLVM 18 ships only the runtime `libLLVM.so.18.1` (no dev
symlink, no static libs), so the stock `llvm-config --libs` errors. The
provision script installs a shim at `/opt/llvm-shim/llvm-config` that links
the shared library instead and exports `LLVM_CONFIG` to it, so `make crystal`
links in the cloud (debug build ~10 min on 4 cores; verified 2026-10-02 with
`gc_spec` and a batch of codegen specs, the full suites not yet run).
When running compiler specs directly with `bin/crystal spec`, pass the
Makefile's flags: `-Dwithout_libxml2 -Dwithout_openssl -Dwithout_zlib`
(the container has no libxml2 dev link).

### On the workstation (macOS)

1. `git pull` on `master` (or the branch you are on).
2. Build as before: `make crystal` (LLVM via `Makefile.local`, see
   `memory/crystal-build-llvm-config.md`).
3. Test services: `eval "$(.agent-context/setup/provision-macos.sh)"` —
   Homebrew postgresql@16 + Valkey, state under `~/.crystal-fork`, ports
   overridable (`PG_PORT=55432 ...`). Written from the verified Linux recipe
   but **not yet run on macOS**; fix and commit it on first use.
4. Copy the memory into the local agent memory if it is not there yet
   (`memory/*.md`), or just read it from here.

### Running the tests

```sh
bin/crystal spec spec/std/postgres/ spec/std/pool_spec.cr spec/std/redis/
# multi-threaded runtime:
bin/crystal build -Dpreview_mt -Dexecution_context -o /tmp/all_mt \
  spec/std/postgres/*_spec.cr spec/std/pool_spec.cr spec/std/redis/*_spec.cr
CRYSTAL_WORKERS=4 /tmp/all_mt
```

Baseline 2026-09-26 (Linux, all env vars set): 597 examples, 0 failures,
2 pending (Redis: no IPv6 loopback, no Unix socket exposed), both runtimes.
Live examples pend (never fail) when a server or env var is missing.
Benchmarks: `harnesses/harness-2026-09-26/postgres/run.sh` (Crystal vs Go
pgx vs Rust tokio-postgres; README there has every result so far).

## Map of this directory

- `memory/`: the persistent agent memory. Start with `memory/MEMORY.md`
  (index), then `stdlib-batteries-direction.md` (everything shipped, user
  decisions, lessons — read its 2026-09-26 entries), `perf-stdlib-backlog.md`,
  `crystal-build-llvm-config.md`, `gc-research.md`.
- `notes/`: long-form reports the memory cites as `.remember/<name>.md`
  (in a fresh clone they live here), the roadmap, review ledgers, and
  `compiler-crash-indexable-ivar-tuples.cr` (a 1.21.0 compiler crash repro;
  the user asked not to report it upstream).
- `harnesses/`: benchmark and differential harness sources (binaries and
  results left out).
- `setup/`: `provision-linux.sh` (cloud/Linux, verified), `provision-macos.sh`
  (workstation).

## Things to know

- Commit hashes in memory from before 2026-09-26 are stale (master was
  rebased onto upstream `89541d678` that day); match commits by subject.
- Machine specifics in older notes (macOS 27, brew LLVM 23, 8 GB RAM, the 14
  known std_spec environment failures) describe the Mac.
- Specs and plans for shipped features are in `docs/superpowers/{specs,plans}/`
  (force-added; `/docs/` is gitignored).
- The user prefers many questions, a light-hearted tone, compiled languages
  (Crystal/Rust backends, Svelte UIs), and wants help with UI work.
