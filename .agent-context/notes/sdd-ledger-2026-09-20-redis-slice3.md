# SDD ledger — plan: docs/superpowers/plans/2026-09-20-redis-slice3.md

Spec: docs/superpowers/specs/2026-09-20-redis-slice3-design.md (read; binding authority).
Branch: redis-slice3 from master 9f9b049d0 (plan commit). Workspace: .superpowers/sdd/2026-09-20-redis-slice3/.

## Pre-flight scan (2026-09-20)

Ruling: implement on branch `redis-slice3` in the main checkout, not a git worktree — `bin/crystal` execs the in-tree `.build/crystal` (a worktree would fall back to the bootstrap compiler against a newer stdlib) and the 8 GB machine allows one compiler at a time; same practice as slices 1 and 2 — cost if wrong: none for master (branch), a dirty checkout for the user while the run lasts.

| Pair / task | Produces vs consumes | Finding |
|---|---|---|
| T1 → T6 | `Cluster.route_key(args : Indexable) : String?` / `Pipeline#record` calls it | consistent |
| T1 → T7 | `SLOTS`, `KEYLESS`, `SPECIAL`, `key_slot`, `route_key` kept verbatim; T7 replaces only the placeholder doc | consistent |
| T2 → T6, T8 | `Pipeline#resolve(i, Value)` / `#fail(i, Exception)`; T6 `pipelined` and T8 resolution loops use exactly these | consistent |
| T2 → T3 | `fail_futures(pipeline, from, error : Exception)` in connection.cr; T3 widens the rescue clauses around it | consistent (T3 edits rescue clauses only) |
| T3 → T5 | `Connection#watching?` cleared by `multi` only when it sent bytes; T5 `watch` ensure uses `watching? && !closed?` | consistent |
| T4 → T5 | `Pool.new(url, size:, checkout_timeout:, db:, …)` / `Client#pool` passes every Client option; `Pool#checkout(&)` / `with_connection(&block)` forwards | consistent |
| T5 → T7 | `Client.new(..., pool_size:)` / `Cluster#node_client` passes `pool_size:` | consistent |
| T5 → T9 | `Client#with_connection`, `Client#watch(*keys, &block)` / `Cluster#with_connection`, `#watch` forward | consistent |
| T6 → T8 | `Pipeline.new(cache, routing: true)`, `routes`, `offsets`, `buffer`; `Client#pipeline_raw(bytes, count, & : Int32, Value, Exception? ->)`, `call_raw(bytes, asking)` / T8 `run_group`, retry loop | consistent |
| T7 → T8 | `execute(slot, redirect = nil, &)`, `route`, `refresh_if_stale`, `REDIRECT_CODES` / T8 uses all four | consistent |
| T7 → T9 | `route(nil)`, `node_uri`, `check_open` / `subscriber`, `with_connection`, `watch` | consistent |
| T7 spec ↔ T8/T9 specs | share `fake_two`, `TWO`, `dead_port`; T8 adds `values` helper once | consistent |
| T9 → T10 | module doc mentions `with_connection`, `Cluster`, `Pool` only | consistent |
| T1 self | spec values (3443, 3300, 15495, 5061, 4015, 8363) computed with an XMODEM CRC reference in the session | agrees |
| T2 self | pure refactor; new pipeline spec exercises `fail`; transaction_spec line 99 switched | agrees |
| T3 self | TLS spec asserts only the mapped class (either IO or SSL branch); `watching?` spec matches the `sent` rule | agrees |
| T4 self | timeout message `"…after 00:00:00.050000000"` matches `/50/` | agrees |
| T5 self | transaction_spec expectations rewritten for pooling (`accepted` stays 2, `UNWATCH` only when no `multi` ran) | agrees |
| T6 self | offsets 0/27/41 hand-counted from the RESP encoding | agrees |
| T7 self | example counts (`accepted(0) == 3`, `slots_calls`) traced through seed-probe-then-client sequence | agrees |
| T8 self | retry order (MOVED then ASK) traced; reload between retries touches node 0 only | agrees |
| T9 self | live MOVED example depends on SETSLOT propagation; plan carries a poll fallback | agrees, watch in execution |
| Rubric | no asserting-nothing tests; the `fake_two` default handler is shared, not duplicated | clean |

Note: plan deviates from spec deliberately (future API split; `pipeline_raw` yields value+error; public `Cluster#node_for`) — recorded in the plan's self-review notes; spec §3.4 wording is superseded by the plan for these three points.

## Progress
Task 1: dispatched (implementer sonnet), BASE 9f9b049d0
Task 1: ⚠️ commit trailer resolved by controller: `git log -1 --format=%B acf32edf6` shows the Co-Authored-By line.
Task 1: minor (deferred): cluster.cr placeholder class doc — Task 7 replaces it (verify at Task 7 review).
Task 1: complete (commits 9f9b049d0..acf32edf6, review clean)
Task 2: dispatched (implementer sonnet), BASE acf32edf6
Task 2: minor (deferred): QueuedFuture#fail comment is not its own :nodoc: (class is nodoc; matches sibling resolve).
Task 2: complete (commits acf32edf6..88e67fc7f, review clean)
Task 3: dispatched (implementer sonnet), BASE 88e67fc7f
Task 3: BLOCKED report — plan defect: a `rescue ex : IO::Error | OpenSSL::SSL::Error` variable is typed `Exception`, so the union-restricted private `fail(ex : IO::Error | OpenSSL::SSL::Error)` no longer matches and overload resolution falls to `Spec::Methods#fail` (compile error in dsl.cr). Ruling: rename the private helper to `lost(ex : Exception) : NoReturn` and widen `connection_error(ex : Exception)`; every `fail(ex)` call in connection.cr becomes `lost(ex)`; rescue clauses stay as the brief wrote them — a union rescue variable is `Exception`-typed by the compiler, so `Exception` is the honest restriction — cost if wrong: an internal private-method name; no public surface. Lesson for memory: union rescue variables are typed `Exception`, and a private method named `fail` collides with spec's `fail` once a union rescue feeds it.
Task 3: ⚠️ commit trailer resolved by controller (git log shows Co-Authored-By).
Task 3: complete (commits 88e67fc7f..ea20129f3, review clean after ruling)
Task 4: dispatched (implementer sonnet), BASE ea20129f3
Task 4: Ruling: plan defect in pool_spec example 5 ("closes idle connections, and in-use ones when they return") — with reuse-first checkout, `idle` and `held` were the same object, so `idle.closed?` after close could not hold; implementer's reorder (checkout `held` before checking `idle` in) keeps every assertion and the intent (one idle closed by close, one in-use closed at checkin). Accepted — cost if wrong: none, the plan text was self-contradictory.
Task 4: review Needs fixes, 1 Important: `closed?` and the checkout fast-path read `@closed` without the mutex. Ruling: the finding conflicts with the plan text (which reads `@closed` unguarded, matching `Client#closed?`'s documented "advisory snapshot" pattern; the constraint wording was the controller's, over-strict) — the reads stand; fix round adds the same advisory-snapshot sentence to `Pool#closed?`'s doc and a comment on the checkout pre-check saying the guarded recheck under the mutex is the real one — cost if wrong: a stale `closed?` answer under a concurrent close, which is already the client's documented contract.
Task 4: minor (deferred): double checkin / foreign checkin undetected (documented sharp edge).
Task 4: minor (deferred): module doc mentions Pool only at Task 10 (planned).
Task 4: fix round 1/5 (1 addressed, 0 open — advisory closed? docs; commits 052c85859..f5c902bdb)
Task 4: complete (commits ea20129f3..f5c902bdb, review clean after ruling)
Task 5: dispatched (implementer sonnet), BASE f5c902bdb
Task 5: minor (deferred): with_connection doc hardcodes "five seconds" (Pool default) in prose.
Task 5: minor (deferred): `close` local `pool` shadows the private `pool` method.
Task 5: complete (commits f5c902bdb..88a5a8a4e, review clean)
Task 6: dispatched (implementer sonnet), BASE 88a5a8a4e
Task 6: Ruling: plan defect — client_spec "yields every reply of pipeline_raw" used `Array({Int32, Redis::Value, Exception?})`, which does not compile (Tuple element inference with the recursive `Value` alias; same family as the known `Tuple#map` quirk). Implementer's rewrite to three parallel arrays with the same assertions is accepted — cost if wrong: none (spec-only shape). Lesson for memory: tuples containing `Redis::Value` inside an Array do not type-check in block iteration.
Task 6: minor (deferred): pipeline_raw's `rescue IO::TimeoutError` also catches one raised by the caller's block (no current caller raises).
Task 6: minor (deferred, plan-mandated): call_raw discards an error reply to ASKING itself (fixed no-arg command).
Task 6: complete (commits 88a5a8a4e..0bea60583, review clean after ruling)
Task 7: dispatched (implementer opus), BASE 0bea60583
Task 7: review Needs fixes, 3 Important (all plan-mandated, all accepted as brief defects): (1) FakeCluster `seen`/`slots_calls` unsynchronised + coalescing assertion depends on single-threaded ordering; (2) `install` mutates live Node `master=`/`id=` before the swap and last-write-wins on a node in two ranges → a routed node can be flagged replica (ArgumentError from get/refresh); (3) no coverage for empty/"?" host substitution, ProtocolError on malformed CLUSTER SLOTS, unassigned-slot fallback. Ruling: fix all three in round 1, plus the Minor `1 << attempt` overflow (cap the exponent); defer the other minors — cost if wrong: a slightly larger fix diff.
Task 7: minor (deferred): redirect with empty host resolves against seed 0's host, not the redirecting node.
Task 7: minor (deferred): Cluster#ask duplicates Client#call_raw(asking: true) (args vs bytes; brief-mandated).
Task 7: minor (deferred): install's dup/compare/swap in two mutex sections — a node_at insertion in between is closed (self-healing).
Task 7: minor (deferred): load_topology/install/Node#client do not check closed; a reload in flight during close can recreate clients.
Task 7: minor (deferred): scan_each yields nothing on a master-less map instead of raising.
Task 7: minor (deferred): @stale/@closed read unlocked (advisory, same pattern as Client).
Task 7: minor (deferred): class doc example uses pipelined/multi before Task 8 lands (resolved by Task 8).
Task 7: minor (deferred): `command(*args, key:)` lacks a return type restriction; Node#to_s undocumented.
Task 7: minor (deferred): `tried` compares host strings so `localhost` vs `127.0.0.1` seed is probed twice.
Task 7: minor (deferred): FakeCluster answers any CLUSTER subcommand with the slots reply (Tasks 8/9 must not send others).
Task 7: fix round 1/5 (4 addressed, 0 open — fake locking + delta assertion; install parse-then-swap first-wins roles; 3 robustness specs; backoff cap; commits 25cdb7786..7a501fdb2)
Task 7: minor (deferred): load_topology does not fall through to the next candidate on ProtocolError (deliberate: malformed reply surfaces).
Task 7: minor (deferred): no spec for one address master in one range and replica in another (verified by code trace).
Task 7: complete (commits 0bea60583..7a501fdb2, review clean after fix round)
Task 8: dispatched (implementer opus), BASE 7a501fdb2
Task 8: Ruling: plan gap — `WaitGroup` is not in the prelude; implementer added `require "wait_group"` at the head of cluster.cr (spec passed only because the spec file requires it). Accepted; Task 10 relocates the require to src/redis.cr with the others — cost if wrong: none.
Task 8: minor (deferred): a ProtocolError from a malformed redirect during the retry phase escapes pipelined with futures unresolved (same as call).
Task 8: minor (deferred): redirect retries inside a pipeline are sequential, one round trip each.
Task 8: review Needs fixes, 2 Important (plan-mandated, accepted as brief defects): (1) run_group's `failures[i] ||= ex` backfill clobbers replies that already arrived in a partially failed group (pipeline_raw yields every index first); (2) run_group rescues only ConnectionError|IO::TimeoutError while pipeline_raw's reconnect handshake can raise CommandError/ProtocolError → spawned fiber dies unhandled with nil replies, caller-run group escapes before wg.wait. Ruling: fix both in round 1 (track `reached`, backfill only the untouched tail; rescue Exception, stale only for the connection classes) and add a partial-failure regression example; the multi doc's `watch` reference becomes true in Task 9 — cost if wrong: a slightly larger diff.
Task 8: minor (deferred): an exception escaping pipelined between yield and resolve leaves every future unresolved (ArgumentError on value).
Task 8: minor (deferred): key_slot computed under @mutex in the grouping loop; unsized IO::Memory for chunks.
Task 8: minor (deferred): `values` spec helper duplicated from transaction_spec (support-file candidate).
Task 8: minor (deferred): no examples for TRYAGAIN/exhausted retry inside a pipeline, keyless-only pipeline, multi with nil first key.
Task 8: fix round 1/5 (3 addressed, 0 open — reached-tail backfill; rescue Exception with scoped stale; partial-failure regression example; commits 5e591d461..1beb6281b)
Task 8: complete (commits 7a501fdb2..1beb6281b, review clean after fix round)
Task 9: dispatched (implementer opus), BASE 1beb6281b
Task 9: Ruling: three brief defects accepted as the implementer resolved them — (1) `yield` inside a captured block does not compile → `Cluster#with_connection` captures and forwards `&block`; (2) `free_port` via port 0 yields macOS ephemeral ports ≥49152 and Valkey refuses port > 55535 (bus port = port + 10000) → `free_ports(3)` probes a random 20000..40000 base requiring node and bus ports free; (3) blocking-command live example leaked its pushing fiber (BLPOP can answer before RPUSH's reply is read; cluster close failed the waiter) → fiber signals a Channel and the example waits — cost if wrong: none (spec/helper shape; no assertion changed). Lessons for memory: yield-in-captured-block; Valkey bus-port ceiling on macOS ephemeral ports.
Task 9: minor (deferred): live helper needs a free port and port+10000 pair in 20000..50000, else every live example is pending (never fails).
Task 9: minor (deferred): the cluster is spawned once per spec process; spec/std/redis/ pays ~1.5 s.
Task 9: review Approved but 2 Important (plan-mandated): (1) REDIS_CLUSTER_URL split without trim/empty removal; (2) live pub/sub example can hang (receive with no deadline). Ruling: fix both in round 1, fold Minor 5c (`@@failure = ex.message` may be nil → never latches) and Minor 6 (`Cluster#subscriber` → `route(nil).client.subscriber(...)`, removes a ten-option duplicate) — cost if wrong: a slightly larger fix diff.
Task 9: minor (deferred): spawn failure deletes node logs (rm_rf on failure path) — only a generic message survives.
Task 9: minor (deferred): TOCTOU between port probe and server bind.
Task 9: minor (deferred): wait_for connections opened outside the ensure; Process.new failing mid-map leaks started nodes.
Task 9: minor (deferred): `values` helper defined in two spec files (support-file candidate, with Task 8's note).
Task 9: minor (deferred): key_slot(keys[0]) computed twice in Cluster#watch.
Task 9: fix round 1/5 (4 addressed, 0 open — env trim, bounded receive, failure latch, subscriber delegation; commits 19cda00ee..3e0cb2fba)
Task 9: minor (deferred): receive_within reads sub.messages directly, so a closed subscriber surfaces Channel::ClosedError instead of ConnectionError (diagnostic only).
Task 9: complete (commits 1beb6281b..3e0cb2fba, review clean after fix round)
Task 10: dispatched (implementer sonnet), BASE 3e0cb2fba
Task 10: DONE report 9a2932119 (Redis suite 295/0/1 pending; std_spec 18920 ex, 14 known env failures, none under spec/std/redis); review dispatched (haiku).
Task 11: dispatched (implementer sonnet, harness only, in parallel with the read-only Task 10 review), BASE 9a2932119
Task 10: review Approved; the one "Important" (trailer unverifiable from the diff) resolved by controller: git log shows Co-Authored-By: Claude Fable 5.1.
Task 10: complete (commits 3e0cb2fba..9a2932119, review clean)
Final review dispatched (fable) over 9f9b049d0..9a2932119, package review-9f9b049d0..9a2932119.diff; Task 11 benchmarks running in parallel (harness only).
Task 11: complete (harness only, no commit; agent cut off by the session rate limit after writing the report and stopping the cluster). Results (medians, Valkey 9.1.2, redis-rs 0.27.6 cluster-async, go-redis 9.22): routing overhead +0.04 µs (target ≤0.5, MET); 64-fiber GET 915k ops/s vs 500k rs (1.83×) vs 179k go (5.13×) MET; split pipeline 177 µs vs 259 µs by hand (1.46×) MET; watch pooled 71.7 µs vs fresh 129 µs = 1.80× (target 2×, MISSED — harness A/B is 3 commands vs 2 because the pooled block never runs multi so UNWATCH is sent; correct behaviour, harness follow-up proposed, no product change); Pool checkout/checkin 45 ns (target <200, MET).
Task 11: Ruling: the missed 2× watch target stands as reported; the extra UNWATCH is required correctness (no watch leak to the next borrower) — cost if wrong: none.
Final review (fable, 9f9b049d0..9a2932119, report final-review.md): "With fixes". Important: (1) Node#close nils the client so a holder recreates an unclosable Client after close/reload (leaks socket + reader fiber; root of two T7 deferred minors); (2) Node#client created outside any mutex (spec §3.1 says under the cluster's mutex; race under preview_mt); (3) pipeline with N MOVED replies reloads ~N times (each retry's route → refresh_if_stale, then the pending MOVED re-marks stale); (4) Client#watch's ensure `unwatch` can replace the block's exception (AbortedError retry loop would not fire). Minor folded: Node#to_s undocumented, `command(*args, key:)` lacks `: Value`. Triage: T7 "install swap vs node_at insertion" and "no closed check in Node#client" fixed via (1); all other deferred minors stay deferred per the report's one-line reasons. Ruling: ONE fix wave with all five items + regression examples, then one scoped re-review — cost if wrong: a larger fix diff.
Final fix wave: 9a2932119..cfd2f3d76 (2 commits); scoped re-review dispatched.
Final fix wave: 5/5 addressed, no new breakage (commits 9a2932119..cfd2f3d76). Parked with rulings (no second wave): (a) a Node created by node_at/install AFTER Cluster#close is neither closed nor flagged (needs a redirect to an unlisted address or a reload racing close) — Ruling: real, deferred to slice 4 backlog, not merge-blocking; every public entry point calls check_open — cost if wrong: one leaked client in a close race. (b) Client#watch's ensure rescues only ConnectionError from UNWATCH; IO::TimeoutError/ProtocolError still replace the block's exception — Ruling: matches the review's recommendation literally; deferred — cost if wrong: a rare masked AbortedError under read_timeout. (c) scan_each doc does not mention ConnectionError from a concurrently closed master — deferred doc nit.
Branch redis-slice3 final HEAD cfd2f3d76 — controller verification then finishing-a-development-branch.
