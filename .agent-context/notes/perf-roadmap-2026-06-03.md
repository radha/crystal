# Crystal stdlib performance roadmap — close the gap with Rust/C++/Go

## Context

Goal: Crystal's stdlib should not be slower than other LLVM frontends (Rust, C++) or Go on
equivalent operations. This roadmap operationalizes the **2026-06-03 comparative audit**
(74 agents, adversarially verified; full report `.remember/comparative-perf-audit-2026-06-03.md`,
distilled in memory `perf-stdlib-backlog.md`). Every item below was re-verified against the
**current `master` (tip `8b56fd555`)** — line numbers are fresh, not from the drifted audit base.

**Decisions driving sequencing** (confirmed with user):
- **Performance fork** (`radha/crystal`): semver-sensitive changes (RNG reproducibility, hash-value
  changes) are *allowed*; upstream selectively later. Still keep each change behavior-preserving
  where it can be, with regression specs + benchmarks, so individual items remain PR-able.
- ~~**Cheap wins first**~~ **SUPERSEDED 2026-06-11 (user decision): reorder by IMPACT** —
  rank by realistic post-verification multiplier × breadth of use. See "IMPACT-ORDERED QUEUE"
  below; phase numbering kept for reference, execution follows the queue.
- **Compiler work is in scope**: the codegen hook (uninitialized malloc) and the LLVM
  vector-intrinsics surface get their own late phase.

## IMPACT-ORDERED QUEUE (re-sequenced 2026-06-11; supersedes cheap-wins-first)

Rank = realistic post-verification multiplier × breadth of use. Done as of re-sequencing:
Phases 0, 1 (6/6), 2.1–2.5, 3 (complete incl. rindex), 6a, 7-capture_count, 4b (driftsort, landed @7d7278c2a).
GC research done 2026-06-13 → **Phase 11** added (6 confirmed of 12; report `.remember/gc-research-2026-06-11.md`).
**Phase 11a (parallel markers) + 11b (heap tuning) DONE 2026-06-13** — merged to master
@`d801b147f` (11a `08852cc57`, 11b `d801b147f`), release compiler rebuilt + self-hosted.

1. **[Phase 4a COMPLETE — `a2bc40973` 2026-06-13]** sort modernization. 4b driftsort done (`7d7278c2a`).
   **4a Step 2 landed as pdqsort scalar restructure + equal-element `partition_left` (NOT the
   branchless block partition, which was REJECTED on measurement — see Phase 4 section).** Result
   (all parity-or-better vs master, zero regressions): low-cardinality **1.4–1.64×** (the broad win,
   from O(n log k) partition_left), sorted/reverse/mo3killer ~1.18–1.21×, random ~1.0–1.06×, float
   1.04×, string parity. Verified 60k+ random × 11 dists × 5 types + exhaustive/boundary sizes + 1M
   stress, byte-identical to stable sort; +2 specs.
2. **Phase 9b — vector-intrinsics surface → 9c SIMD UTF-8 (10–20×) → 9d SIMD Base64/hex (7–10×)**.
   Largest raw multipliers left; 9b has zero direct speedup but gates 9c/9d/9e/8d-SIMD.
   This is the big schedule change vs cheap-first: compiler track moves UP. Med-High risk.
3. **Phase 5 — IO.copy/File.copy kernel copy** (copy_file_range/sendfile/clonefile): >10× on
   reflink FS, 1.3–2× plain. Narrow-ish surface, huge factor. Med risk.
   **[macOS File.copy clonefile DONE — `b9604c3d2` 2026-06-13]**: `File.copy` now reflinks via
   `fclonefileat` (darwin) for regular-file sources with an absent dst → **72× (16 MiB) / 863×
   (256 MiB), O(1) in size (~0.15 ms flat)**. `fcopyfile` for the dst-exists path was REJECTED on
   measurement (~22% slower than the read/write loop @256 MiB) → overwrite/non-APFS/non-regular keep
   the unchanged `IO.copy` (zero regression). Seam `Crystal::System::File.copy_clone?` (false on
   non-darwin). **[Linux File.copy copy_file_range DONE — `07e773298` 2026-06-13]**: `copy_data` seam
   (false on non-linux) → `copy_file_range(2)` loop (1 GiB cap, null offsets, 3-state Atomic support
   probe via invalid-fd EBADF disambig, fall back only when written==0 on {ENOSYS,EOPNOTSUPP,EPERM,
   EXDEV,EINVAL,EBADF,EIO,EOVERFLOW}+0-byte-first; EINTR retry; written>0 errors fatal). Port of
   Rust/Go. Android excluded (NDK API 34). **CROSS-COMPILE-VERIFIED ONLY (gnu/musl/i386/android) +
   2-agent reference review (no blockers); NOT runtime-tested on Linux — needs CI before upstreaming**
   (safe-by-fallback: any unexpected written==0 condition → unchanged IO.copy). **Still queued:
   (b) IO.copy file→socket sendfile** (static-file serving; touches the event loop for non-blocking
   sockets — larger surface).
4. **[DONE — `d801b147f`] Phase 11b — GC heap presizing + free_space_divisor** (added 2026-06-13):
   shipped public `GC.free_space_divisor`/`GC.free_space_divisor=`/`GC.presize_heap`, env vars
   `CRYSTAL_GC_INITIAL_HEAP`/`CRYSTAL_GC_FREE_SPACE_DIVISOR` (k/m/g suffix, all platforms incl. Windows;
   parsed from raw C string, no early-init alloc), + **opinionated 8 MB default heap floor**
   (set `=0` to disable; only grows, never shrinks/overrides larger). **Measured (--release, 20M
   short-lived String allocs): default floor cut collections 1300→62, wall 263→218 ms (~18%); RSS of
   a near-empty program UNCHANGED (floor commits no pages — lazy).** gc_none no-ops. Low risk.
5. **[DONE — `08852cc57`] Phase 11a — GC parallel markers at GC.init** (added 2026-06-13): default
   binaries marked on one core (libgc spawns markers lazily at first wrapped `pthread_create`);
   `GC_start_mark_threads()` once in `GC.init` + restart in fork-child callback (non-preview_mt unix).
   Bound `GC_start_mark_threads`/`GC_get_parallel` (non-win32/non-wasm/libgc≥8.2.0; gc_none no-op).
   **Measured (--release, 8 cores, 241 MB pointer-bearing heap): full GC.collect 257.7→78.4 ms = 3.3×;
   GC_get_parallel 0→7 at startup, restored to 7 in forked child (0 without callback).** Amplifies 11c.
6. **Phase 6b — branchless civil_from_days** (Hinnant/Neri–Schneider): 1.5–3× per decomposition,
   underlies every Time field/format access; compounds with merged 6a memo. Med risk.
7. **Phase 8 — hash chain 8a→8b→8c→8d**: rapidhash 1.3–1.8× (≥32B keys), SwissTable realistic
   1.2–1.4×. Modest multiplier but Hash is ubiquitous → large aggregate. Highest effort/risk;
   8d-SIMD wants 9b first (SWAR fallback fine without).
8. **[DONE 2026-06-14] Phase 5 — JSON lexer pair** (both stdlib-only, byte-identical, on master):
   - string SWAR (`f3d387b2f`): `StringBased#consume_string` scans the closing quote a machine word at a
     time for ASCII content, bails to the exact original per-codepoint loop on the first `>=0x80` byte.
     **24.6× (100KB string) / 7.3× (1000×64-char) / 1.67× (object keys) / 1.38× (short); non-ASCII parity
     (−2.7% worst case).** Far exceeded the 1.2-2× est — per-codepoint Char::Reader was a huge bottleneck.
   - number inline int-cache (`afcf0717d`): `consume_number` accumulates the magnitude inline and caches
     it on the token when `digits<=18` (always fits Int64 → identical to `to_i64`); `>=19` digits + floats
     fall back unchanged; `raw_value` untouched. **1.1-1.4× int-heavy JSON.parse.**
   - Verified byte-identical over 3 string differentials (1.9M random + exhaustive 0..40 + long 50..256
     deep-marker, full token stream incl column/error positions) + a number differential (overflow exceptions
     included); 4-agent adversarial review found no real bugs. +45 specs. **NOT done: lazy raw_value (the
     bigger alloc-elimination 1.3-2× — DEFERRED, risky: raw_value persistence semantics + IOBased asymmetry);
     `consume_string_skip` SWAR; IOBased string SWAR (needs peek).**
9. **Phase 5 — File.read presize (1.5–2×) + buffered writev (~2× syscalls)**. Low/Med risk.
10. **Phase 9a — uninitialized malloc + Phase 11d skip redundant NORMAL memset**: 9a 1.2–1.6× large
    primitive dup/concat (atomic path); 11d ~0.1–0.5% macro (NORMAL double-zero) — complementary
    codegen memset-elimination, land together. Med / Low-Med risk.
11. **Phase 11c — GC precise-heap marking via custom bdwgc kind** (added 2026-06-13): 5–20% mark-time
    on mixed heaps; per-alloc fast path needs a vendored libgc (raised `THREAD_FREELISTS_KINDS`). Large,
    Med-High risk (wrong offset table = UAF). Structural; shares pointer-layout tables with 11e-stage3
    escape analysis (RFC-0004) — the biggest structural lever Crystal lacks.
12. **Phase 10 — raise lazy CallStack** (big only for exception-as-control-flow), SpinLock→Sync::MU
    (MT), acquire/release atomics (ARM), RNG bit-stuffing (semver, fork-OK).
13. **Long tail**: 7-jit_match (3–10%), name_table memo, integer-parse SWAR (long decimals only),
    6c leap_year/parse allocs, 2.6 read_char ASCII runs (deferred), **Phase 11f skip no-op
    shrink-realloc** (resolves the formerly-deferred Builder shrink-realloc — analysis now done; use a
    `GC_size` predicate; ~3–5% micro, strongest on large builders), **11e-stage1 LLVM alloc attributes**
    (~0–1% macro), deque/array micro-wins, VERIFY-FIRST checks.

## Status / merge resolution (the "merge optimize-time-formatter to master" ask)

**Already done — nothing to merge.** Local `master` tip `8b56fd555` ("Optimize Time formatting
pad2/pad4…") has a **patch-id identical** (`5096a76c…`) to the topic-branch commit `40048c5af`.
The time-formatter work was rebased onto master and is already present, using the shared
`Crystal::DIGIT_PAIRS` (`src/int.cr:74`, referenced from `src/time/format/formatter.cr:259-278`).
The only diffs between the stale `optimize-time-formatter` branch and master are *upstream* spec
changes (`Process.capture`) the branch predates — **zero `src/time` differences**. Working tree is
clean (only untracked `CLAUDE.md`).

**Phase 0 cleanup (execute on approval):**
- `git branch -D optimize-time-formatter` (stale pre-rebase duplicate; content is in master).
- Decide `fork/optimize-time-formatter` (currently `40048c5af`, pre-rebase): leave as snapshot, or
  force-update to `8b56fd555`. Recommend leaving it; PRs (if opened) go from fresh branches off master.
- `master` is 21 commits ahead of `origin/master` (3 perf commits + rebased upstream). No push unless asked.

## Working method — Definition of Done for every change

Reuse the proven workflow (from `perf-stdlib-backlog.md`):
1. Branch off `master`. One focused change per branch.
2. **Behavior-preserving proof** (for output-identical changes): differential harness — capture
   output over millions of inputs, `git stash` the baseline, rebuild, diff **byte-for-byte**.
3. `bin/crystal spec spec/std/<file>.cr` passes (bootstrap compiler + in-tree src, no full rebuild).
   Add **regression specs** for edge cases (boundaries, empty, multibyte, overflow).
4. `make format`.
5. **Benchmark** with `Benchmark.ips`, built `--release`, **3× runs** to beat machine noise; record
   before/after numbers in the commit message. Benchmarks are ad-hoc `.cr` files (no `benchmark/`
   dir; `src/benchmark/` is the library). Keep scratch benches in `.remember/` or `/tmp`.
6. For **semver-sensitive** items (fork-allowed): explicitly document the behavior change.

Bootstrap crystal 1.20.2 at `/opt/homebrew/bin/crystal`; prebuilt `.build/crystal` exists.

**Per-item integration workflow (user directive, 2026-06-03):** after each item is
fully verified (DoD above), **merge its branch to `master`** (linear: ff or rebase-then-ff),
then **rebuild the compiler as a release build**:
`make crystal release=1 interpreter=1`. Requires `LLVM_CONFIG` exported to the
latest brew LLVM — persisted in `Makefile.local` as
`export LLVM_CONFIG=/opt/homebrew/opt/llvm/bin/llvm-config` (currently 22.1.6). The
`make` var alone isn't enough; it must be *exported* so the inner `bin/crystal build`
sees `env("LLVM_CONFIG")`. Release rebuild ≈ 3m40s. Smoke-test via `bin/crystal`
(sets CRYSTAL_PATH), not `.build/crystal` directly.

**MERGED to master so far:** item1 `02729110c` (Enumerable min/max count), item2
`f81c7825d` (JSON::Builder escape table), item3 `c3d0763a3` (sprintf int zero-alloc),
item4 `d9f7b9443` (String#byte_index(Int) → memchr), item5 `b722100bf` (URI.encode run-batch + hex LUT).
item6 `2ead5ea28` (String#hexbytes? decode LUT). master tip = `2ead5ea28`.
Compiler rebuilt (release, LLVM 22.1.6) at item6. **Phase 1 COMPLETE (6/6).**

**item6 finding — the originally-planned ENCODE LUT is INVALID; pivoted to DECODE.**
`Slice#hexstring`/`to_hex` (`src/slice.cr:634-660,794`) must STAY arithmetic: LLVM already
auto-vectorizes `to_hex` into NEON `.16b` ops (cmhi/bsl/and/add, 16 bytes/iter — confirmed in asm).
A pair/nibble LUT forces scalar gather loads → **7-13× REGRESSION** on bulk (size ≥64); only helps
size-16 by ~6ns (alloc-dominated, irrelevant). Do NOT revisit hex *encode* as a LUT.
The real win was the symmetric DECODE path: `String#hexbytes?` (`src/string.cr`) called
`Char#to_u8?(16)` twice/byte (no vectorization) → replaced with 256-entry `HEX_DECODE` table
(`0xff`=invalid). **1.9-2.4× at ALL sizes, no regression.** 520k-input differential byte-identical,
+regression specs. General lesson: before a "scalar→LUT" perf change, check `--emit asm` for existing
autovectorization — a LUT defeats it.

---

## Phase 1 — Cheap, measured, self-contained wins (week 1)

Each is its own branch; mostly output-identical (pure perf). Highest leverage / lowest risk first.

1. **[DONE — branch `optimize-enumerable-min-max-count`, commit `02729110c`]**
   **`Enumerable#min(count)`/`max(count)` are Θ(count·n)** — `src/enumerable.cr:1231` / `:1118`
   (helper `quickselect_internal` `:1056`). Today: `(0...count).map { quickselect_internal(...) }`
   restarts quickselect *per output element*. Fix: one `quickselect(n-count)` then sort/heap the
   count-tail. **~50-100× for top-k (k~n/2)**, ~no change for k=1. Risk Low. (Note: no
   `min_by(count)`/`max_by(count)` overloads exist — scope is the two `min/max(count)` methods.)
   **RESULT (measured, far exceeded estimate): n=10k — max(n/2) 112.6ms→354µs (~318×), max(n)
   225ms→610µs (~369×), min(n/2) 112.5ms→370µs (~304×), max(10) 297µs→25µs (~12×), min(10)
   373µs→102µs (~3.6×).** Differential harness ~30k cases byte-identical (SHA-256 match); +3
   regression specs each (count==size, low-cardinality, randomized sort-reference + no-mutation).
   310 enumerable specs green, formatted.
2. **[DONE — branch `optimize-json-builder-escape`, commit `20df4e00b`]**
   **`JSON::Builder` escape classifier** — `src/json/builder.cr:155-177`. Already run-batches
   passthrough via `write_string`; only swap the per-byte chained `case` for an `ESCAPE[256]` table
   (serde_json style). **Measured 1.99×–2.27×** in the audit microbench. Risk Low.
   **RESULT: long sparse 2.34µs→1.19µs (~1.97×), short 16c 103ns→92ns (~1.12×), escape-heavy
   1.23µs→805ns (~1.53×).** NOTE: naive table version regressed escape-heavy ~13% because short
   escapes were emitted as two `IO#<<` Char writes; fixed by writing the 2-byte `\x` escape in one
   `write_string` (stack `UInt8[2]`). Differential digest byte-identical over all bytes + 65 536
   pairs + 1000 random strings; +2 regression specs; 616 JSON specs green.
3. **[DONE — branch `optimize-sprintf-int-noalloc`, merged `c3d0763a3`]**
   **printf/sprintf `%d/%x/%b/%o` allocates a throwaway String** — `src/string/formatter.cr:274`.
   `arg.to_s(base)` heap-allocs but only bytesize/content is used. Stream via the existing zero-alloc
   `Int#to_s(io, base, precision:, upcase:)` (`src/int.cr:805`). Removes 1 alloc+copy/specifier;
   ~1.2-1.8× on `String#%`. Risk Low.
   **RESULT: 8× per call — %d 374ns/448B→277ns/224B (~1.35×, −50% bytes), %x ~1.33× −46%, %#x ~1.32×
   −30%, mixed ~1.33× −45%; %08d flat time (per-char zero-pad) but −40% bytes.** Approach: added
   `:nodoc:` `Int#to_s_digits` yielding bare digits from the existing `internal_to_s` stack buffer
   (no heap); split `Formatter#int` into `int_primitive` (streaming) vs `int_allocating` (BigInt).
   **TWO GOTCHAS (both verified/fixed):** (1) a separate `int(flags, arg : Int::Primitive)` overload
   is NEVER selected — loses specificity to `int(flags, arg : Int)` in the formatter's call context
   (confirmed by STDERR instrumentation); must branch with `is_a?(Int::Primitive)` INSIDE the `Int`
   overload (folds at compile time for concrete types). (2) routing BigInt through `to_s_digits`
   SIGSEGVs — BigInt inherits the fixed 129-byte `internal_to_s`; restrict fast path to
   `Int::Primitive`. Differential digest byte-identical over all flags×width×precision×conv × every
   primitive-width edge value + BigInt; 117 sprintf specs; +1 regression spec (primitive≡BigInt).
   Pre-existing unrelated `String#encode`/iconv failures on this machine (also fail on master).
4. **[DONE — merged `d9f7b9443`]** **`String#byte_index(Int)` ignores bound memchr** —
   `src/string.cr:3759`. Delegated to `to_slice.fast_index(byte.to_u8!, offset)`
   (`src/slice.cr:1228`, wraps `LibC.memchr`). **CORRECTNESS GUARD added** (`return unless
   0 <= byte < 256`): memchr interprets its value mod 256, but the old `UInt8 == Int`
   comparison only matched 0..255 — e.g. `0x16f` must NOT alias `0x6f`. Offset semantics
   preserved via `check_index_out_of_bounds` (normalizes negatives, nil past-end), verified
   at empty/offset==bytesize/OOB boundaries. **RESULT (--release 3×, runtime-opaque inputs to
   defeat DCE — first bench was bogus, scalar got constant-folded to 0.96ns flat): 12B hit
   parity (~1.0×, memchr call overhead ≈ short loop); 201B+`\n` each_line 77ns→7.7ns (~10×);
   10k miss 3.22µs→227ns (~14×); 10k hit-near-end 3.23µs→242ns (~13×).** Differential harness
   byte-identical over 86,853 cases; +3 regression specs (NUL, out-of-range guard incl.
   mod-256 aliasing, full 0..255 range). 1070 string specs (only the 3 pre-existing
   iconv/encode shift-state failures, also red on master).
5. **[DONE — merged `b722100bf`]** **`URI.encode` per-byte emit + `byte.to_s(io,16)` per escape** —
   `src/uri/encoding.cr:310`. Verbatim bytes now accumulate and flush as one `write_string` of a
   sub-slice; escapes write a 3-byte `"%XY"` from a 16-entry upper-hex nibble LUT (`HEX_UPCASE`).
   `yield`-call sequence unchanged (ASCII-non-space only, same short-circuit) ⇒ byte-identical.
   **RESULT (--release 3×, runtime-opaque 200B inputs): mostly-verbatim path 1.03µs→775ns (~1.33×);
   escape-heavy 1.90µs→1.35µs (~1.40×); mixed query 1.85µs→1.38µs (~1.34×).** (Under the 1.5-3×
   estimate but consistent.) Differential byte-identical over 750 combos (15 strings incl. full
   0..255 byte string + 60 random × 5 real-wrapper predicates × space_to_plus on/off); +2 regression
   specs (run-batch flush boundaries). 249 uri_spec + 63 params_spec green.
6. **Hex codecs per-nibble arithmetic** — `src/slice.cr:634-660` (`hexstring`/`hexdump`), `to_hex`
   helper `:794`; `String#hexbytes` path. 256-entry `UInt16` pair LUT (single 16-bit store/byte).
   **1.3-1.5× bulk** (few % for the 16-32 B digest/UUID callers where alloc dominates). Risk Low.

**Also fold in still-valid zero-risk internal-audit items** — EVALUATED 2026-06-03:
- **`includes?`→`index` (memchr): DONE `df2809d7a`.** Added `Indexable#includes?` → `!index(obj).nil?`.
  `Bytes#includes?` 4.5× (64B) / 13.6× (4K) / 15.7× (64K) vs scalar `any?`; non-byte parity. +3 specs.
- **`Enumerable#map` dead index counter: SKIPPED — premise false.** Range/Array/Slice/StaticArray/
  Tuple/NamedTuple ALL override `map` already; the base is reached only by Set/Hash/custom Enumerables
  where array doubling-growth dominates and the unused index increment is noise (LLVM DCEs it). Not worth it.
- **`Array#reverse` → dup+reverse!: SKIPPED — current is already faster.** The single-pass gather
  `Array.new(size){@buffer[size-i-1]}` beats dup(memcpy)+reverse! (two passes) by 1.04-1.11×.
- **`String::Builder#to_s` shrink-realloc threshold: DEFERRED (Med risk, not zero).** It `GC.realloc`s
  to exact size on every `String.build` (ubiquitous). Skipping when slack is small trades memory for
  speed — needs a memory-regression analysis + Boehm size-class check (realloc-shrink within a class
  may already be no-copy). Revisit deliberately, not as a "cheap win".

---

## Phase 2 — memchr / SWAR byte-scan fast paths (week 1-2)

Coherent theme; share one differential test harness over random byte buffers + multibyte strings.

1. **[DONE — merged `b7421f7c3`]** **`Slice(UInt8)#count(byte)` + `#rindex(byte)`** — `src/slice.cr`
   (were falling through to scalar `Enumerable#count` `:266` / `Indexable#rindex`; both confirmed
   unvectorized via `--emit asm`). `count` uses a branchless wrapping-add tally
   (`count &+= ptr[i] == byte`) — LLVM auto-vectorizes to `cmeq.16b` reduction (NO manual SWAR / NO
   popcount needed; the popcount-haszero idea is WRONG for counting — borrow propagation skews
   per-byte flags, so popcount of haszero overcounts. haszero *presence* IS exact, though). `rindex`
   hand-rolls SWAR word-at-a-time reverse (no memrchr binding): broadcast byte, XOR, haszero presence
   test per 8-byte window, scalar-refine matching word high→low. Both guard `T.is_a?(UInt8.class)` +
   `0<=item<256`, else `super`. **GOTCHA (regression caught): `Indexable#rindex` returns the offset's
   own integer type** (`offset.downto` is offset-typed; spec asserts `be_a(Int64)` for Int64 offset) —
   fast path must `return typeof(offset).new(idx)`, not Int32. Scan internally in signed Int32 (fits;
   signed keeps `>=0` correct for unsigned offsets). **RESULT (--release 3×, runtime-opaque, consumed
   acc): count 64B 3.8× / 256B 5.1× / 4K 5.3× / 64K 5.4×; rindex full-scan(miss) 64B 4.2× / 256B 3.9×
   / 4K 4.8× / 64K 5.1×; rindex hit-at-end (scalar's best case) tie within noise.** Differential
   byte-identical 27,368 cases (all 256 byte values for count; neg/OOB/mid offsets for rindex across
   sub-word/word/vector boundary sizes); +regression specs incl. offset-type preservation. 132
   slice_spec + full string_spec green (only the 3 pre-existing iconv failures). Also speeds
   `String#rindex(Char)` ASCII (delegates to `to_slice.rindex`).
2. **[DONE — merged `11da508a0`]** **`String#count(Char)` decodes every codepoint** —
   `src/string.cr:2930` (was `count { |char| char == other }` → `each_char`/Char::Reader).
   `single_byte_optimizable?` + `.ascii?` → `to_slice.count(byte)` (the new fast path); REPLACEMENT
   → count high bytes (each invalid byte decodes to one REPLACEMENT); other non-ASCII → 0. Mirrors
   `#index(Char)` structure. Genuine multibyte unchanged. **RESULT (--release 3×, runtime-opaque
   ASCII, consumed acc): 64B 6.0× / 256B 5.9× / 4K 6.6× / 64K 6.0×.** Differential byte-identical vs
   each_char ref over ASCII/invalid-UTF8/multibyte/edge needles; +regression specs (empty, absent,
   replacement counting, non-ASCII-in-ASCII-string→0, multibyte). 58 count specs green.
3. **[DONE — merged `2a98b2652`]** **`String#split(Char)` uses `Char::Reader`** —
   `src/string.cr:4152` (block form). `single_byte_optimizable?` + `separator.ascii?` → loop
   `to_slice.fast_index(byte, offset)` (memchr) instead of decoding every codepoint. Preserves
   `yielded`/`byte_offset`/`remove_empty`/`limit` semantics + `String.new(ptr, bytesize)` piece ctor
   exactly; multibyte & non-ASCII/REPLACEMENT separators keep the Char::Reader path. **RESULT
   (--release 3×, allocations UNCHANGED — pure scan-cost cut, so speedup scales with field length):
   7-char fields (alloc-dominated) 1.10-1.16×; 80-char 3.0×; 200-char 3.7×; 1000-char 4.9×.**
   Differential byte-identical vs Char::Reader ref over 2208 cases (both remove_empty; limits
   nil/1/2/3/5/100; leading/trailing/consecutive seps; no-match; multibyte content w/ ASCII sep;
   invalid bytes; multibyte & REPLACEMENT seps). +regression specs. 77 split specs green. LESSON:
   first bench used tiny 7-char fields → only 1.1× (allocation-dominated, NOT representative); had to
   bench long fields to surface the real 3-5× win. Match field size to where the cost actually moved.
4. **[DONE — merged `67e72647f`]** **`String#size` + `ascii_only?` scalar (two passes)** —
   `src/string.cr:5489` / `:5532`. **PIVOTED from the planned non-continuation-count design** (that
   matches Crystal's `size` ONLY for valid UTF-8 — `char_bytesize_at` counts each invalid byte as 1
   codepoint, so counting non-continuation bytes diverges on invalid input). Instead: `size` keeps the
   exact `char_bytesize_at` semantics but **bulk-skips runs of ASCII bytes a word at a time**
   (`(ptr+i).as(UInt64*).value & 0x8080808080808080 == 0` → +8 bytes/+8 chars), deferring every byte
   `>=0x80` to `char_bytesize_at` — provably byte-identical for ALL inputs incl. invalid UTF-8 (a byte
   `<0x80` is always 1-byte-1-codepoint at a boundary). `ascii_only?` exploits `ascii_only? ⟺ no byte
   >= 0x80`, dropping the size computation and the 2nd pass: a single **OR-reduction** `acc |= ptr[i]`
   (auto-vectorizes to `orr.16b`; an early `return` would block it). **RESULT (--release 3× median,
   cold, alloc-inclusive): size ascii 256B 3.4× / 4KB 3.7× / 64KB 4.2×; size mixed 4KB 1.9×;
   ascii_only? 256B 5.8× / 4KB 7.5× / 64KB 9.1× / mixed-false 4KB 6.2×.** **CRITICAL GOTCHA (caught by
   spec SIGSEGV, not the differential harness): ASCII string LITERALS live in read-only memory with
   `@length` preset by the compiler (`build_string_constant` bakes `@length = str.size >= 1` for every
   non-empty literal incl. invalid UTF-8). Must memoize `@length` ONLY when `@length == 0`** (the
   "size unknown" sentinel ⟹ heap ⟹ writable), exactly as `size` already guards. The differential
   harness used `String.new(slice)` (always heap, `@length=0`) so it never exercised the literal path —
   the existing `"a".ascii_only?` spec did. Word load gated by `byte_index <= (bytesize &- 8)` (no OOB,
   guard-page verified). `ascii_only?` no longer caches `@length` on its false path (analyzed safe: no
   caller depends on the side effect; `@length==0` is tolerated everywhere). Byte-identical over ~17M
   diff inputs + 1M+ adversarial fuzz vs the release compiler (3-lens adversarial workflow, all
   refuted=false); +9 regression specs. Compiler release-rebuilt (LLVM 22.1.7), self-hosted clean.
   **Fork push BLOCKED by auto-mode classifier (master push needs explicit user auth); local master =
   `67e72647f`, fork/master 1 behind, awaiting `git push fork master:master`.**
5. **`gets(String delimiter)` byte-at-a-time + per-hit memcmp** — `src/string`/`src/io.cr:844`
   (memcmp `:875`). Peek+memchr-anchor on the last byte (mirror the single-byte `gets_peek` fast path
   at `src/io.cr:694`). **2-4× buffered each_line**. Risk Med.
6. **`read_char`/`each_char` decode 1 byte/iter over ASCII runs** — `src/io.cr:303`. SWAR-scan peek
   for first ≥0x80, yield the ASCII run, single `skip(run_len)`. **2-4× read_char**. Risk Med.

---

## Phase 3 — Substring search rewrite (week 2)

**[byte_index(String) DONE — `2a6d80833`]** Hybrid memchr-anchor (`to_slice.fast_index(first_byte)` +
memcmp) with Go-style miss-counter cutover (`fails >= 4 + offset>>4`) to the existing Rabin-Karp
(extracted verbatim into private `byte_index_rabin_karp`). **sparse 100KB 129µs→2.04µs (63×); dense
NO regression (~1.00×, cutover essential — bare anchor regresses 3.67×); small-miss 8.7×.** Byte-
identical (dense/sparse/multibyte/invalid/30k-random) + 2 specs. Follow-ups (separate PRs, NOT done):
`split(separator:String)` anchor (`string.cr:4256`), `index(String)` (char-index conversion),
`rindex(String)`. Note `includes?(String)`→`index(String)` (its own RK), NOT byte_index.

One coherent unit (drives `include?`/`split`/`gsub`/`scan`/`partition`); heavy differential testing,
preserve char-vs-byte index semantics.

- Replace Rabin-Karp with **memchr-anchored** first-byte scan (reuse `Slice#fast_index`) + memcmp,
  with a Go-style failure-count cutover back to RK, **or** bind `LibC.memmem` (Two-Way). Sites:
  `byte_index(String)` `src/string.cr:3827`, `index(String)` `:3377`, `rindex(String)` `:3527`
  (SWAR reverse — no memrchr), naive `split(String)` `:4200`. **4-10× index/byte_index/includes? on
  large sparse haystacks**; gsub/scan smaller (allocation-diluted). Risk Med.
- Reference design: Rust `memchr::memmem` (rare-byte AVX2/NEON prefilter + Two-Way), Go `bytealg.Index`.

---

## Phase 4 — Sort modernization (week 2-3)

Pure `src/slice/sort.cr`; strong correctness suite (stability checks + adversarial inputs). `sort!`
routes primitives here (`Slice#sort!` `src/slice.cr:1017`, `unstable_sort!` → `intro_sort!`).

- **4a — pdqsort / ipnsort (unstable)**: replace branchy Hoare `partition_for_quick_sort!`
  (`:169`) with branchless BlockQuicksort (offset buffer + cyclic swaps), ninther pivot for large n,
  `partial_insertion_sort` already-sorted short-circuit, bad-partition shuffle + `BAD_ALLOWED=log2 n`
  → keep `heap_sort!`. Add branchless sort4/sort8 networks for n≤8 leaves (replace `insertion_sort!`
  `:185` at the bottom). **2-2.4× random primitives, up to 10×+ adversarial**. Risk Med.
  **[Step 1 DONE — `c77dd64cc` 2026-06-11]** No-swap short-circuit + bounded partial insertion
  (first partition iteration peeled — a per-swap flag store cost 12% on few-unique). **sorted
  3.1×/4.2×(block), reverse 2.7×/3.4×, all other patterns parity.** **NINTHER REJECTED on
  measurement**: 5-9% cost on random/low-cardinality, zero adversarial benefit over the depth-guard
  (tested thresholds 128/1024/∞).
  **[Step 2 DONE — `a2bc40973` 2026-06-13]** Restructured to pdqsort's scheme (median-to-front pivot,
  pivot excluded from recursion, `leftmost`+`partition_left` equal-element skip → O(n log k)). The
  **branchless block partition (BlockQuicksort) was IMPLEMENTED then REJECTED on measurement** — the
  whole reason Step 2 was queued. Faithful port (UInt8 offset buffers + cyclic swap_offsets!) only
  won large high-entropy inputs (100k random 1.37×, float 1.47×) while REGRESSING the common cases:
  **n=1000 random ~2×, large nearly-sorted/reversed up to ~1.9× slower** — Crystal's scalar Hoare is
  already tight, so the per-element offset store outweighs the avoided mispredictions until the
  working set outgrows the branch predictor. A size threshold fixed small-n but NOT large
  nearly/reverse (their cost is in the big top-level partitions). Kept only the scalar structure +
  partition_left → clean parity-or-better everywhere, low-cardinality **1.4–1.64×**. Ninther stays
  rejected (no branchless partition to amortize it). **Phase 4 sort track now complete.** Verified
  2.75M differential fuzz (Int32/UInt8/Float64/String) + 544 specs + 5 regression specs.
- **4b — driftsort (stable)**: replace the pre-driftsort TimSort `merge_sort!` (`:257`, `Array(Range)`
  run stack) with Rust 1.81 driftsort (powersort merge order + branchless small-sort). **up to ~17×
  low-cardinality, >2× random**. Risk Med. (The run-stack cleanup alone is ~nothing — the win is the
  algorithm.)
- **4c — `Indexable::Mutable#sort!` in-place** for contiguous mutables (StaticArray, user types) —
  `src/indexable/mutable.cr:336` currently gathers into a temp Slice + scatters back. Sort in place
  over the pointer. Removes 1 alloc + 2 copies. Risk Low.

---

## Phase 5 — IO & numeric / codec batch (week 3)

Independent PRs.

- **`IO.copy`/`File.copy` never use kernel copy** — `src/io.cr:1302-1334`, `src/file.cr:660`.
  Wire `copy_file_range`/`sendfile`/`splice` (Crystal already binds `LibC.sendfile` + ships
  `Socket#sendfile`); macOS `copyfile(COPYFILE_CLONE)`/`clonefile` for APFS reflink. **>10× large
  File.copy on reflink FS**, ~1.3-2× plain. Detect-once-cache, fall back on ENOSYS/EXDEV. Risk Med.
  **[macOS clonefile DONE — `b9604c3d2`]**: `File.copy` → `fclonefileat` reflink for regular-file src
  + absent dst (72×/863×, O(1)); `Crystal::System::File.copy_clone?` seam (false on non-darwin).
  `fcopyfile` rejected (22% slower @256 MiB).
  **[Linux DONE — `07e773298`]**: `copy_data` seam → `copy_file_range(src.fd, nil, dst.fd, nil,
  0x4000_0000, 0)` loop in `src/crystal/system/unix/file.cr` (reopened `lib LibC` under
  `flag?(:linux) && !flag?(:android)`, pthread.cr precedent), 3-state `Atomic(Int32)` probe
  (compare_and_set on success; invalid-fd EBADF disambiguates seccomp), fall back **only when
  written==0** on {ENOSYS,EOPNOTSUPP,EPERM,EXDEV,EINVAL,EBADF,EIO,EOVERFLOW}+0-byte-first; EINTR
  retry; written>0 errors fatal. Port of Rust `copy_regular_files`. **CROSS-COMPILE-VERIFIED ONLY
  (gnu/musl/i386/android) + 2-agent reference review; NOT runtime-tested on Linux — exercise via
  CI before upstreaming** (the existing File.copy specs cover it; safe-by-fallback).
  - **Still queued: IO.copy file→socket** = route through existing event-loop `sendfile`
    (non-blocking sockets) — static-file HTTP serving; larger surface.
  Full understand-pass (Go/Rust fallback chains, lib_c inventory, Fd/buffering safety) in workflow
  output `tasks/w9ed1r0nz.output` (this session); copy_file_range review `tasks/wpk5s97yy.output`.
- **Buffered writes do copy+write, not `writev`** — `src/io/buffered.cr:139`. 2-iovec `LibC.writev`
  for drain+direct-slice. **~2× syscall reduction**. Risk Med.
- **`File.read`/`gets_to_end` doubling Builder, no presize** — `src/io.cr:584`. File override: fstat
  → `String.new(size)` → read_fully. **1.5-2×** + fewer allocs. Risk Low.
- **Integer parse scalar char-at-a-time** — `src/string.cr:678`. SWAR 8-digit chunk (rust-lexical/
  Lemire) for **long decimals (8-19 digits) into wide types only**; typical 1-4 digit ints unchanged.
  Risk Med.
- **JSON number double-pass** (raw String then re-parse) — `src/json/lexer/string_based.cr:81` →
  `token.cr:20`. Accumulate `Int64` inline during lex; keep `raw_value` lazy. **1.3-2× int-heavy**. Med.
- **JSON string lexing per-codepoint** — `src/json/lexer/string_based.cr:14`. SWAR terminator mask
  (serde_json). **1.2-2× end-to-end**. Risk Med.

---

## Phase 6 — Time / calendar math (week 3-4)

Builds on the just-finished formatter work.

- **[DONE — `2484f6fc7`] 6a — Formatter re-decomposes per field** — `src/time/format/formatter.cr`.
  Memoized `@ymd` tuple from `Time#year_month_day_day_year`; year/month/day/day_of_year read it.
  Memo persists across `#visit` (format calls visit on a local struct var). **1.18-1.23× on multi-
  date patterns (to_rfc3339 1.23×, %Y-%m-%dT%H:%M:%S 1.22×); single-field/no-date controls flat.**
  Byte-identical over 2.36M Times × 12 patterns; +1 spec.
- **6b — branchless `civil_from_days` / `days_from_civil`** — `src/time.cr:1562` (two sequential
  bucket loops + month loop), inverse `absolute_days` `:1535` (per-month sum). Port Hinnant /
  Neri–Schneider (libstdc++ since GCC 11): era math + `mp=(5*doy+2)/153`. **1.5-3× per decomposition**;
  underlies year/month/day/date/day_of_year/calendar_week/to_s/strftime → **compounds with 6a**. Med.
- **6c — `leap_year?` raising bounds-check + month/day-name parse allocs** — `src/time.cr:1092`;
  `src/time/format/parser.cr` (per-token `byte_slice`+`capitalize`+closure scan). Non-raising internal
  leap variant; case-insensitive in-place name compare vs static tables. Risk Low.

---

## Phase 7 — Regex (week 4)

`src/regex/pcre2.cr`.

- **[capture_count DONE — `0b1ca8456`] Memoize `@capture_count` + name_table** on the immutable
  Regex — `:203` (FFI per match). PCRE2 `match_impl` now memoizes via `@capture_count ||= ...`
  (legacy PCRE already cached in `@captures`). **cc 3.38→2.42ns (1.4×); gsub ~6%.** +1 spec.
  name_table memo NOT done (would need `dup` in public accessor to keep the mutable-Hash contract).
- **Elide the ovector `dup`** for bool/index matchers (`=~`, `index(Regex)`, `starts_with?(Regex)`) —
  `src/string.cr:5349`, dup at `src/regex/pcre2.cr:218`. Keep `$~` assignment (user-observable). The
  zero-alloc `matches_impl` (`:223`) already exists as the model. **10-40% on validation loops**. Risk Low.
- **Use `pcre2_jit_match`** when `@jit && NO_UTF_CHECK` — `@jit` stored but `pcre2_match` always called
  (`src/regex/pcre2.cr:270`). ~3-10% short subjects (scan/gsub already pass NO_UTF_CHECK). Risk Med.

---

## Phase 8 — Hash function + SwissTable (week 4-5+) — biggest structural; enablers first

Fork allows the hash-value change (Hash iteration is **insertion-ordered** and independent of the hash
function, so changing it is safe; no documented hash-value guarantee).

- **8a — enablers (low risk, land first)**: hoist the per-probe 3-way `case @indices_bytesize`
  (`src/hash.cr:750-780`) into monomorphized `probe_u8/u16/u32` variants; cache `@indices_mask`
  (recomputed in `fit_in_indices` `:946`). Clean refactors, help vectorizable build/compaction loops.
- **8b — rapidhash/mum hash function** — `src/crystal/hasher.cr:263` (serial 8-byte funny_hash).
  16-byte/round `mum(a,b)=lo^hi` with native `UInt128` product (one `mulx`). **1.3-1.8× keys ≥32B**.
  Risk Med. **Semver-sensitive (fork-OK).**
- **8c — stop 64→32 truncation / carve a UInt8 fingerprint** — `src/hash.cr:990` (`to_u32!`), Entry
  `@hash:UInt32` `:2227`. Enables the SwissTable h2 fingerprint.
- **8d — SwissTable control-byte group probing** — `src/hash.cr:399-537`. Parallel 1-byte control
  array of 7-bit fingerprints + EMPTY/DELETED sentinels; `movemask(cmpeq)` over 16 slots (SWAR
  fallback first, SSE2/NEON via Phase 9b later). **Index into the ordered `@entries`** to preserve the
  insertion-order guarantee. Unlocks O(1) tombstone delete (reuse `do_compaction` `:599`) and load
  factor 0.5→~0.875 (`entries_capacity` `:985`). **Realistically 1.2-1.4×** (Crystal's already-low
  load factor + ≤16-entry linear-scan tables cap it — *not* the 2-5× headline). Risk High. Depends 8a-8c.

---

## Phase 9 — Compiler / codegen + SIMD surface (week 5-6+) — the compiler track

User opted in. These need codegen/runtime work, not just stdlib.

- **9a — uninitialized malloc** — codegen `src/compiler/crystal/codegen/codegen.cr:~2350`
  (`generic_array_malloc` unconditional `memset 0`). Add `Pointer(T).malloc_uninitialized(n)`
  (pointer-free types only) for pure-overwrite sites (`dup`/`+`/`*`/`[](start,count)`/`skip`/`map`).
  **Must keep zeroing for `Array.new(size, value)` zero/null fast path** (`src/pointer.cr:569`).
  **1.2-1.6× large primitive dup/concat**. Risk Med, scope=both (small codegen hook).
- **9b — vector-intrinsics surface** — `src/intrinsics.cr` binds only scalar ops. Bind a few LLVM
  vector intrinsics (`pshufb`, `pmovmskb`, `vector.reduce.*`) via `<N×i8>` + codegen support + CPUID-
  cached dispatch + scalar fallbacks. Pure enabler (zero direct speedup); `fun` can't natively spell
  LLVM vector types → real codegen work. Risk Med-High. Unlocks 9c/9d/8d-SIMD.
- **9c — SIMD UTF-8 validate/count** (simdutf / Lemire–Keiser) — upgrades Phase-2 SWAR for
  `Unicode.valid?` (`src/unicode/unicode.cr:73`) + `String#size`. **10-20×**. Depends 9b.
- **9d — SIMD Base64 (Muła–Lemire `vpshufb`) + hex** — upgrades Phase-1/Phase-5 SWAR.
  `src/base64.cr`, `src/slice.cr`. **7-10× bulk**. Depends 9b.
- **9e — SwissTable SSE2/NEON probe** — upgrade 8d's SWAR group-compare to real `movemask`. Depends 9b + Phase 8.

---

## Phase 10 — Fork-only semver-sensitive & concurrency (opportunistic)

From the internal audit; fork allows these.

- **RNG**: `rand(Float)`/power-of-two bound use rejection+modulo where bit-stuffing / `& (n-1)` suffice
  — `src/random.cr:141/219`. **Changes seeded sequences** (semver). Risk Med.
- **Atomic CAS default `:sequentially_consistent`** → `:acquire`/`:acquire_release` for stdlib-internal
  callers — `src/atomic.cr` (ARM/Apple-Silicon win, no-op x86).
- **`raise` eagerly allocates CallStack** even when backtrace unused — `src/raise.cr` (lazy capture).
- **`Crystal::SpinLock` unbounded busy-spin** → bounded spin + backoff; migrate Channel/WaitGroup onto
  `Sync::MU`. See backlog "CONCURRENCY / GC / EXCEPTIONS".

---

## Phase 11 — GC / allocation track (added 2026-06-13)

From the GC/bdwgc deep-research report `.remember/gc-research-2026-06-11.md` (bdwgc 8.2.12,
homebrew, macOS ARM64 + Linux). 6 of 12 candidate opportunities survived adversarial
premise+feasibility verification; impacts below are **post-verification (corrected)**. The 6
rejected ones (incl. GMP→`malloc_atomic`, which *reproduced heap corruption*) are recorded in
that report's "Rejected / downgraded" section so they are not re-litigated.

Collector-level (runtime; the quick wins):

- **[DONE — `08852cc57`, 2026-06-13] 11a — parallel marker threads at `GC.init`** — `src/gc/boehm.cr:211-224`. Default
  (non-`preview_mt`) binaries mark on **one core forever**: libgc is built with `PARALLEL_MARK`
  but marker threads spawn only at the first wrapped `pthread_create` or an explicit
  `GC_start_mark_threads()`. Bind `GC_start_mark_threads` + `GC_set_markers_count` (call the
  latter **before** `LibGC.init`), call `GC_start_mark_threads()` after init, reset markers in
  non-exec fork children (`process.cr:223`). **Measured 1.5–2.9× faster mark phase ≥~20 MB heaps**
  (~2–10% wall on alloc-heavy; ~0 for small-heap CLIs). Ref: D shipped this default-on (DMD 2.087).
  Risk Low-Med (ncpu−1 sleeping threads/process; cgroup-quota-unaware `GC_get_nprocs`). Effort
  Small. First step: 30-line patch, confirm `GC_get_parallel()` flips 0→>0, rerun `std_spec`.
- **[DONE — `d801b147f`, 2026-06-13] 11b — heap presizing + `free_space_divisor` exposure** — all
  three tiers shipped incl. the opinionated 8 MB floor; see impact-queue rank 4 for results. Original plan:
  `src/gc/boehm.cr:211-224` set zero knobs. Three tiers: (a) document `GC_INITIAL_HEAP_SIZE`/`GC_FREE_SPACE_DIVISOR`/`GC_MARKERS`
  (already work, **zero code**); (b) bind `GC_set_free_space_divisor`/`GC_expand_hp` + honor a
  `CRYSTAL_GC_INITIAL_HEAP` env (Windows needs this tier — env vars are compiled out there); (c)
  opinionated init-heap floor (8–16 MB) for the fork. GOGC analog (bdwgc collects ~every
  `heapsize/divisor`, default 3). **5–30% wall on alloc-heavy/compiler-like** (measured: compiler
  frontend `FSD=1` 6.4–7.9s→4.6–4.8s; 64M floor cut 81 GCs→1 for a 32MB workload, +0.6MB RSS).
  Risk Low (RSS-vs-CPU tradeoff). Effort Small. First step: env-only benchmark matrix.

Structural (research track):

- **11c — precise-heap marking via a custom bdwgc kind** (Whippet backend spike as endgame) —
  Track A: register one `GC_new_kind`+`GC_new_proc` whose mark proc dispatches on the `type_id`
  word at offset 0 (`codegen.cr:2270-2273`) and walks compiler-emitted per-type pointer-offset
  tables (extend `has_inner_pointers?`, `types.cr:54-99`, to full offset lists, Julia-style).
  Track B: `src/gc/whippet.cr` behind the pluggable seam (`gc.cr:139-143`, precedent `-Dgc_none`).
  **5–20% full-GC mark-time on mixed heaps** (the 4.4× headline is adversarial ceiling, not
  typical); durable win is robustness (no scalar-induced false retention). **Mutator-side
  neutral-to-slower on stock libgc** (custom kind has index ≥3 → bypasses thread-local freelists →
  global lock/alloc) until a vendored libgc raises `THREAD_FREELISTS_KINDS`. Risk Med-High
  (wrong offset table = collected live object — memory-unsafe). Effort Large. Shares the per-type
  pointer-layout tables with 9a/9b precision work and the RFC-0004 escape track (11e stage 3).

Codegen / stdlib allocation (small; overlap the Phase 9 compiler track):

- **11d — skip the redundant memset after NORMAL-kind `GC_malloc`** — `codegen.cr:2266-2267`
  (`pre_initialize_aggregate`) + `:2350-2361` (`generic_array_malloc`) always memset, but
  `GC_malloc` (NORMAL) guarantees cleared memory (`gc.h:651-655`) → pointer-bearing class instances
  and Array/Hash buffers are **zeroed twice**. Keep memset for the atomic/PTRFREE path, c_malloc
  fallback, `Reference.pre_initialize`, and the `alloca` branch; flag-gate. **~1.03–1.12× on the
  alloc op, macro ~0.1–0.5%** (smaller than hoped: duplicate memset runs cache-warm). Risk Low-Med
  (every allocator path must uphold the contract). Effort Small. **Sibling of 9a** (9a targets the
  atomic/uninitialized path; 11d targets the NORMAL already-zeroed path — land both).
- **11e — LLVM allocator attributes on `GC_malloc`/`_atomic`** — attach `noalias`/`allocsize(0)`/
  `allockind("alloc,zeroed|uninitialized")`/`"alloc-family"` to the LibGC externs (`codegen.cr:2363-2429`,
  attr machinery `:1334`); needs LLVM≥15 + binding support for `allockind`/string attrs. Lets LLVM
  delete dead allocations + fold memsets (what Rust `__rust_alloc`/Swift `swift_allocObject` emit).
  **Stage 1 ~0–1% macro** (microbenchmark-only wins). **Stage 2** = sink unconditional closure-env
  alloc (`:2054-2059`,`:2127-2167`) to first Proc materialization (~0–2%). **Stage 3 = Go-style
  escape analysis → `alloca` (5–15% alloc-volume, multi-month) — this is the owned version of the
  acknowledged structural blocker / RFC-0004**, the single biggest lever Crystal lacks. Risk:
  stage1 Med-soundness (`zeroed` must NOT go on atomic/c_malloc), stage3 memory-unsafe. Refuted
  sub-claim: memset-folding for *escaping* pointers needs `memory(inaccessiblemem:readwrite)`,
  unsound for bdwgc+Crystal (slow-path GC runs finalizers + the fiber-stack push callback) — get
  that win via 11d instead.
- **11f — skip the no-op shrink `GC.realloc`** in `String.new(capacity)`/`String::Builder#to_s`
  (`string.cr:279-281`, `string/builder.cr:108-111`+`143-146`) — **resolves the long-tail's deferred
  "Builder shrink-realloc" item**: bdwgc `GC_realloc` shrink (`mallocx.c:165-178`) returns the SAME
  pointer after a pointless tail `BZERO` whenever `new ≥ slot/2` (reclaims nothing); only below half
  does it move+free. Skip it iff bdwgc would reclaim nothing, gated on a **`GC_size` predicate**
  (`GC.size` already bound, `boehm.cr:163`). **~3–5% on in-band string-construction micro; strongest
  on large builders ≥64KB–1MB (`IO#gets_to_end`)** where the skipped `BZERO` is tens-to-hundreds of
  KB; macro <0.1–0.2%. **MUST use `GC_size`** — the naive `≥ capacity/2` predicate regresses RSS
  (the half-rule is vs the granule/block-rounded slot); never touch the `<half` move path (net win
  today). Risk Low. Effort Small.

Suggested sequencing: 11a + 11b are top-tier quick wins (see queue ranks 4–5); 11d ships with 9a;
11f with the stdlib batch; 11c + 11e-stage3 are structural (compiler-track tier with Phase 8/9b).

---

## Dependency notes

- Phase 8d (SwissTable) depends on 8a-8c. Its SIMD upgrade (9e) depends on 9b.
- Phases 9c/9d (SIMD UTF-8 / Base64) depend on 9b; their **SWAR fallbacks already ship** in Phases 2/1/5,
  so value lands early and 9b only raises the ceiling.
- Phase 6a is a prerequisite mindset for 6b (decompose-once before swapping the decomposition algo).
- Phases 1-7 are mutually independent and can be reordered freely. Phases 3 and 4 are the two
  highest-value structural-but-stdlib-only units; either can go first.
- Phase 11a/11b are zero-dependency quick wins (ship anytime). 11d ships with 9a (both memset-
  elimination). 11c (precise marking) and 11e-stage3 (escape analysis, RFC-0004) share the same
  compiler-emitted per-type pointer-offset tables — sequence them after the 9b compiler track. 11c's
  per-alloc fast path additionally hard-depends on a vendored libgc (raised `THREAD_FREELISTS_KINDS`).

## Verification (end-to-end)

Per the Definition of Done above, for each change:
- `bin/crystal spec spec/std/<file>.cr` green + new regression specs.
- Differential harness byte-identical vs baseline for output-preserving changes.
- `Benchmark.ips` `--release`, 3× runs, before/after recorded.
- `make format`; for structural changes also `make std_spec` once before merging the phase.
- Full report of confirmed impacts + reference designs: `.remember/comparative-perf-audit-2026-06-03.md`.

## References

- Comparative report: `.remember/comparative-perf-audit-2026-06-03.md` (71 findings, 32 confirmed).
- GC/bdwgc report (Phase 11): `.remember/gc-research-2026-06-11.md` (12 candidates, 6 confirmed + 6 refuted, w/ verifier evidence + bdwgc 8.2.12 internals + comparative GC designs).
- Memory backlog (this + internal audit long-tail): `perf-stdlib-backlog.md`.
- Already best-in-class (do not churn): Dragonbox (float→str), fast_float/Eisel-Lemire (str→float),
  GMP, Stein gcd, `Int#to_s`/Time two-digit tables (shipped), bit-op intrinsics, hardware sqrt.
