# Agent context

Working notes for this fork, committed so a fresh session (for example a cloud session)
starts from the same place as the local one. None of this is part of the Crystal
distribution.

- `memory/`: the persistent agent memory, snapshotted 2026-09-26. Start with
  `memory/MEMORY.md` (the index), then:
  - `stdlib-batteries-direction.md`: the fork's goal (a batteries-included stdlib), what has
    shipped (binary, Heap, `Binary::Format`, Redis slices 1-3) and the lessons learned.
    **Next up: Tier 3a Postgres, or the Redis slice 4 residuals.**
  - `perf-stdlib-backlog.md`: the stdlib perf work, shipped / rejected / queued.
  - `crystal-build-llvm-config.md`: the LLVM/build setup and test baselines.
  - `gc-research.md`: bdwgc tuning findings.
- `notes/`: long-form reports that the memory files point to as `.remember/<name>.md`.
  In a fresh clone they live here instead. The full roadmap is
  `notes/batteries-roadmap-2026-09-17.md`.
- `harnesses/`: benchmark and differential harness *sources* from `.remember/harness-*`
  (binaries and results are left out). Some compare against Rust/Go baselines
  (`harnesses/harness-2026-09-19/redis/{rs,go}`).

Things to know:

- Commit hashes cited in memory from before 2026-09-26 are stale: master was rebased onto
  upstream `89541d678` that day (tip `0f0dd0aae`). Match commits by their subject line.
- Machine specifics in the notes (macOS 27, brew LLVM 23 via `Makefile.local`, 8 GB RAM,
  the 14 known std_spec environment failures) describe the local Mac, not other hosts.
  On Linux, `LLVM_CONFIG` auto-detection usually works, and the Linux-only paths
  (`copy_file_range`) have never been run there. That makes Linux a good place to verify them.
- Test baselines on 2026-09-26 (macOS): std_spec 18944 examples / 14 environment failures
  (5 iconv, 8 TCP, 1 empty `$PATH`), primitives_spec 716/0, compiler_spec 13729/0.
- Specs and plans for the shipped features are in `docs/superpowers/{specs,plans}/`
  (force-added; `/docs/` is gitignored).
