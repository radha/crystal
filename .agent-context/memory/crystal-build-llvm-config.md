---
name: crystal-build-llvm-config
description: How to build the Crystal compiler locally — LLVM_CONFIG must be set explicitly (pinned to brew llvm@22 since 2026-09-16 because LLVM 23 miscompiles --release builds); the lld linker override from 2026-09-15 is no longer needed
metadata:
  node_type: memory
  type: project
  originSessionId: 07eef577-2c18-4ab0-abc0-679ac046fb0f
  modified: 2026-09-16T04:25:33.827Z
---

Building the Crystal compiler here requires `LLVM_CONFIG` set; the Makefile cannot
auto-detect it on this machine (`llvm-config` is not on PATH). Persisted in
`Makefile.local` (gitignored). User preference: **prefer the latest brew LLVM**, BUT:

**LLVM 23 is broken for Crystal (as of 2026-09-16):** brew `llvm` 23.1.1 makes the
compiler miscompile every `--release` / `-O1+ --single-module` binary: adjacent
narrow struct stores get merged keeping only the first value (LibC::Kevent `flags`
becomes 0xffff → `kevent` ENOENT → every program aborts at startup with
"Thread#execution_context cannot be nil"). Only the in-process module is affected
(llc on the emitted IR is fine). Upstream: issue crystal-lang/crystal#17413, one-line
fix PR #17414 (`unit.compile(isolate_context: true)` in `sequential_codegen`).
Until that lands, `Makefile.local` pins
`export LLVM_CONFIG=/opt/homebrew/opt/llvm@22/bin/llvm-config` (brew keeps `llvm@22`
as a dependency of the `crystal` formula). Re-check after `brew upgrade` or when
#17414 merges; then switch back to `/opt/homebrew/opt/llvm/bin/llvm-config`.
Diagnostic tell: `bin/crystal build --release hello.cr` crashes → LLVM mismatch.
Also: the `opt/llvm` symlink moving under an already-built `.build/crystal` silently
re-points its libLLVM (compiler reports the new LLVM version) — rebuild after LLVM upgrades.

**Linker:** the `LDFLAGS = -fuse-ld=ld` override added 2026-09-15 (brew `ld64.lld`
22.1.8 rejected the macOS 27 SDK `.tbd` stubs) is NO LONGER NEEDED since brew `lld`
23.1.1 (verified 2026-09-16: hello-world and full compiler build link fine with the
auto-picked `-fuse-ld=lld`). Removed from `Makefile.local`; no `--link-flags` needed
for direct `bin/crystal` runs either. The "object file was built for newer macOS"
ld warning is harmless.

Release build of the compiler: `make crystal release=1 interpreter=1`.
Per the perf-roadmap workflow, after each verified item: merge branch to `master`,
then rebuild the compiler (release). See [[perf-stdlib-backlog]].

- **2026-09-19 LLVM 23 status re-checked after upstream sync (origin/master ee5f095bd):** PR #17414 still OPEN, so `--release` builds on brew llvm 23.1.1 still miscompile (symptom now: `Thread#execution_context cannot be nil` at startup). SEPARATE fork-only bug found and FIXED (commit after c589b000f): our Phase 10 backtrace's `LibIntrinsics.returnaddress` was declared as unmangled `llvm.returnaddress`, which LLVM 23 rejects at module verification ("should be llvm.returnaddress.p0") — gated on `Crystal::LLVM_VERSION >= 23.0.0` in `src/intrinsics.cr` like `frameaddress`. Non-release programs now build and run under LLVM 23. Throwaway compiler linked against LLVM 23 is at `.build/crystal-llvm23` (build: `LLVM_CONFIG=/opt/homebrew/opt/llvm/bin/llvm-config bin/crystal build -D strict_multi_assign -D preview_overload_order -Dwithout_libxml2 -Dwithout_openssl -Dwithout_zlib -o .build/crystal-llvm23 src/compiler/crystal.cr`, ~3 min) — use it to re-test once #17414 merges. Keep LLVM_CONFIG pinned to llvm@22 until then.
- **2026-09-19 23:25 LLVM 23 VERIFIED WORKING on the fork with two local commits on master (unpushed at write time): `9bdbf22d2` returnaddress `.p0` mangling (fork-only bug) + `ab99c0e02` cherry-pick of upstream PR #17414 (`unit.compile(isolate_context: true)` in `sequential_codegen`; PR still open upstream). Control: pure upstream w/o the PR reproduces `Thread#execution_context cannot be nil` in every `--release` program; with the PR it runs. Release compiler built against brew llvm 23.1.1 (`.build/crystal-rel23`, 1.22.0-dev [ab99c0e02]) passes std_spec 18781 ex with the same 14 env failures; primitives_spec 716/0 and compiler_spec 13715/0 ALSO GREEN under LLVM 23 (logs `.build/*_llvm23.log`). `.build/crystal` remains the llvm@22 build (backup `.build/crystal-llvm22-keep`). To UNPIN: drop the `export LLVM_CONFIG=…llvm@22…` line from `Makefile.local` and `make clean crystal release=1 interpreter=1` — all three suites are confirmed green on LLVM 23, so unpinning is safe. Earlier unexplained failure of one release test right after a rebuild was not reproducible (0/40 later runs); treat as stale-binary artefact.
- **2026-09-20 UNPINNED: `Makefile.local` now exports `LLVM_CONFIG=/opt/homebrew/opt/llvm/bin/llvm-config` (brew's current keg, 23.1.1; keg-only so `find-llvm-config.sh` cannot auto-detect it — an explicit export is still required, just no longer version-pinned). Active `.build/crystal` = 1.22.0-dev [ab99c0e02] linked to libLLVM.23.1 (`make crystal release=1 interpreter=1`, ~4 min). Fork pushed `c589b000f..ab99c0e02`. Rebuild after any `brew upgrade llvm`. Throwaway binaries removed; `.build/crystal-llvm22-keep` retained as a fallback LLVM 22 build until the next clean rebuild.

- **2026-09-26 REBASED onto upstream origin/master `89541d678` (20 new upstream commits incl. #17432 "Support LLVM 23.1 and 24.0" = const_int high-bit zeroing; our `9bdbf22d2`-equivalent returnaddress.p0 fix + cherry-picked #17414 still needed, #17414 still NOT merged upstream); clean rebase, 153 fork commits, tip `0f0dd0aae`; backup tag `backup/pre-rebase-2026-09-26`; old binary `.build/crystal-pre-rebase-2026-09-26`. brew llvm now 23.1.2. Verified: release+interpreter build OK, std_spec 18944 ex / same 14 env failures, primitives 716/0, compiler_spec 13729/0, format clean. Force-pushed to fork (cfd2f3d76→0f0dd0aae). All earlier fork hashes in memory are STALE — map by subject line.**
