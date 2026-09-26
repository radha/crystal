---
name: gc-research
description: "Crystal GC/bdwgc deep-research report — 6 confirmed + 6 rejected GC perf opportunities, ranked, with file:line and verifier evidence"
metadata: 
  node_type: memory
  type: project
  originSessionId: 41e6be89-e186-4501-877d-c36836dfd214
---

Deep GC/bdwgc research completed 2026-06-13 (resumed a quota-killed multi-agent workflow). Full report: `.remember/gc-research-2026-06-11.md` in the repo (bdwgc 8.2.12 internals, Crystal's GC integration with file:line, comparative GCs Go/Nim-Swift/OCaml-GHC/D-Julia-Immix-MMTk/Mono-SGen). Source data preserved under `.remember/tmp/gc-resume/` (opps.json, verdicts.json, verified.json, digest.md, assemble.py, synth-workflow.js).

**6 CONFIRMED opportunities** (both adversarial premise+feasibility passed), best-ROI first:
1. Start bdwgc parallel marker threads at `GC.init` — default single-threaded binaries mark on ONE core (markers spawn lazily); `GC_start_mark_threads()` = measured 1.5–2.9× faster mark phase. Best ROI, small effort. `src/gc/boehm.cr:211-224`.
2. Heap presizing + `free_space_divisor` exposure — Crystal sets zero GC knobs; GOGC analog, 5–30% wall on alloc-heavy. Small.
3. Precise-heap marking via custom bdwgc kind (Whippet endgame) — 5–20% mark-time; needs codegen per-type pointer-offset tables. Large.
4. Stage-1 LLVM allocator attributes → escape analysis (RFC-0004 endgame). Small→multi-month.
5. Skip redundant memset after NORMAL `GC_malloc` (codegen double-zeros). `codegen.cr:2266/2350`. Small.
6. Skip no-op shrink `GC.realloc` in String.new/Builder#to_s (must use GC_size predicate). `string.cr:279-281`. Small.

**6 REJECTED** (refutations recorded): GMP→malloc_atomic (reproduced heap corruption); fiber-stack GC_push_all (aborts on mark-stack overflow in 8.2.x); vendored static libgc preset (UAF hazard); finalizer no_order (no measured speedup); GC_malloc_many fast path (named sites are stack structs); incremental/generational (fork-veto premise false on threaded build).

Implementable quick wins waiting: items 1 and 2. Relates to [[perf-stdlib-backlog]].

**STATUS 2026-09-16 (all 6 confirmed items now acted on; hashes on fork master):**
- 11a parallel markers + 11b heap tuning: SHIPPED earlier (see index).
- 11f skip no-op shrink realloc: SHIPPED `dc7e01a07` — `GC.shrink_atomic` (GC_size-gated, HBLKSIZE=4096 hardcoded since libgc exports no getter; small slot = granule size, large = block-rounded, skip iff new >= slot/2 exactly mirroring mallocx.c GC_realloc). `String.build` 600KB in 1MB 1.5-1.9×, 40B builder 1.14×, tiny strings ±5% layout noise, File.read unchanged (presized, never shrinks).
- 9a + 11d memset elimination: SHIPPED `b7602cdab` (stdlib `Pointer(T).malloc_uninitialized`, degrades to zeroed malloc for pointer-bearing T; used in Array capacity ctor, `Pointer.malloc(size,&)`, `Slice#dup/#clone`; 1.2-1.6× large pointer-free buffers, small neutral) + `3b8272b74` (codegen drops memset after NORMAL `GC.malloc` — relies on the documented "GC.malloc clears" contract, gc_none clears explicitly; kept for alloca/atomic/c_malloc/pre_initialize). 11d alone ≈ neutral (memset ran cache-warm) — matches prediction.
- 11e stage-1 LLVM allocator attrs: SHIPPED in `3b8272b74` — noalias ret + allocsize + allockind(alloc,zeroed|uninitialized|realloc|free) + "alloc-family"="GC_malloc" on __crystal_malloc*/GC_malloc*/GC_realloc/GC_free (LLVM≥15 guard; applied at definition AND every cross-module `declare_fun`; no `noalias` on GC_free — void return fails the verifier). VERIFIED: LLVM 22 deletes dead GC allocations (3 unused allocs in a loop body vanish; benchmark blocks that discard the result drop to loop overhead). NO memory(...) attrs (finalizers may run inside GC_malloc). Semantics note: a dead `Foo.new` may now never execute (finalizers/GC.stats side effects) — same as Rust/Swift/C++.
- 11c precise marking: BUILT as OPT-IN `-Dgc_precise` `025f136de` — custom `GC_new_kind`+`GC_new_proc` mark proc walking codegen-emitted per-type word-offset tables (`__crystal_gc_layouts[type_id]` → `i32 n, i32 off[n]`; null → conservative full scan via GC_size; free-list objects safe). **SPEED CLAIM REFUTED on stock libgc 8.2.12/ARM64: full GC 2M small objs 21.5→32.3 ms, 500k payload-heavy (1 ptr+30 words) 13.2→23.5 ms — proc dispatch + non-inlined GC_mark_and_push cost more than skipped scalar words; mutator: escaping Node.new 8.4→13.8 ns (global-lock alloc path, custom kind ≥3 bypasses thread-local freelists), JSON.parse −5%, Hash +3%.** Robustness WIN confirmed: 64 MB garbage referenced only via Int64 copies of addresses freed (66 MB) vs retained (0 MB). Default builds unchanged (layouts only emitted when prelude defines `__crystal_malloc_object64`). Making it pay would need a vendored libgc (BITMAP/gcj-style per-object descriptor + THREAD_FREELISTS_KINDS raise) — DON'T retry on stock libgc.
- 11e stage 2 (sink closure-env alloc): SCOPED OUT 2026-09-17 — `codegen.cr` `malloc_closure` is called from `alloca_vars` (def entry) and from every `visit(Yield)` whose block has closured vars; the context IS the closured vars' storage from their first access, so the malloc can only sink to the first access (a rare branch-only win), and the per-yield allocation is semantically required (each iteration's binding may escape). Stage 3 (escape analysis → alloca, RFC-0004) remains a multi-month compiler project; needs a real escape-analysis pass, not a session item. See [[perf-stdlib-backlog]] queue-drain batch. **Stage 3 PARKED by user 2026-09-18 after briefing** (RFC-0004 = crystal-lang/rfcs PR #4, OPEN since 2024-02, never accepted; rules: escapes if stored to global/class/ivar, returned, closured, pointerof, passed to C; finalizer must run before return incl. unwind; drawback = larger conservative stack scan). If ever un-parked: design doc vs RFC rules → intraprocedural-only prototype behind a flag → measure alloc volume before any interprocedural summaries.

