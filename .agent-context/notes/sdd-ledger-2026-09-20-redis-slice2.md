# SDD ledger — plan: docs/superpowers/plans/2026-09-20-redis-slice2.md
Spec: docs/superpowers/specs/2026-09-20-redis-slice2-design.md (read; binding authority)
Branch: redis-slice2 (in place, no worktree). Ruling: branch in the main working tree, not a linked worktree — a worktree would fall back to the bootstrap compiler (no .build/crystal) and double memory on the 8 GB box; slice 1 used the same approach — cost if wrong: none beyond the usual branch discipline.
Redis server: valkey started on 6379 for live specs (Task 7).

## Pre-flight scan (2026-09-20)
| Pair / task | Produces vs consumes | Finding |
|---|---|---|
| T1→T2 script.cr | T1 Script{source,sha}; T2 adds load + ScriptCache | consistent |
| T1→T7 publish | def_command publish → live spec r.publish | consistent |
| T2→T3 pipeline.cr | T2 Pipeline.new(cache), @futures, AbstractFuture#resolved?, ScriptFuture; T3 Transaction.new(@script_cache), tx.futures, QueuedFuture#resolved? | consistent |
| T2→T4 | Client/Connection script_cache; Connection#pipelined uses Pipeline.new(@script_cache) | consistent |
| T3→T4 | Pipeline#multi(& : Transaction ->) : Future(Array(Value)); Client/Connection multi(&block) → p.multi(&block) | consistent |
| T4→T7 | Client#multi/watch signatures used verbatim in live specs | consistent |
| T5→T6 subscriber.cr | T6 replaces run, adds reconnect_loop/resubscribe using T5's drop/connect/@close_signal/Ack(nil waiter) | consistent |
| T5→T7 | Subscriber.new named params = Client#subscriber forwarding list | consistent |
| Global "no slice 1 signature changes" vs T2 | script_args is private (widened to Indexable); Pipeline.new gains an optional param (explicitly allowed) | ok |
| T1 self | spec uses Digest::SHA1 in spec file; redis.cr requires digest/sha1 | ok |
| T4 self | chunk expectations [1,1,4] assume loopback delivers the buffer in one read (same assumption as slice 1 batching spec) | accepted |
| T5 self | unsubscribe/punsubscribe and resubscribe have near-duplicate 8-line blocks | accepted small duplication; reviewer may flag, rule then |
| T5 self | read_timeout example: caller-side drop then reader closes (reconnect: false) | consistent with run() |
| Rubric | no asserting-nothing tests; no verbatim logic duplication beyond the above | clean |

## Progress
Task 1: minor (deferred): src/redis.cr module doc "Not in this slice" line stale — Task 8 rewrites it.
Task 1: complete (commits c707e2309..e37ae51a5, review clean)
Task 2: Ruling: reviewer Important "Pipeline#initialize comment names Connection#pipelined, which does not exist" — comment stands; Task 4 adds Connection#pipelined passing @script_cache exactly as described, so the comment is true at slice end — cost if wrong: a stale one-line comment, caught by the final whole-branch review.
Task 2: minor (deferred): Pipeline#script_run duplicates the enqueue sequence of typed_call (private enqueue helper possible).
Task 2: minor (deferred): Script#load only tested on Connection, not Client.
Task 2: minor (deferred): no concurrent-fiber stress test on ScriptCache.
Task 2: complete (commits e37ae51a5..f2d6abbc1, review clean after ruling)
Task 3: note: plan defect worked around — Crystal cannot dispatch an abstract def through a non-generic base when only a generic ancestor implements it; ScriptFuture and ExecFuture restate `resolved?` (super-only). Reviewer reproduced the limitation. Lesson for memory.
Task 3: minor (deferred): duplicate rationale comments on the two resolved? restatements.
Task 3: complete (commits f2d6abbc1..11ebabae5, review clean)
Task 4: Ruling: plan defect — a typed splat (`*keys : String`) cannot be called with zero args (verified: "given 0, expected 1+"), so the brief's `raise ArgumentError if keys.empty?` is unreachable. Accept the implementer's zero-arg overloads on Connection#watch / Client#watch. Carry into Task 5: Subscriber#subscribe/#psubscribe get a zero-arg overload raising ArgumentError; #unsubscribe/#punsubscribe get a zero-arg overload meaning "all" — cost if wrong: two extra one-line overloads per method.
Task 4: note: values() spec helper rewritten (Tuple#map with recursive alias does not compile); Connection#pipelined rescue split into per-type clauses (union-typed arg through Pipeline#resolve hits the same virtual-dispatch limitation as Task 3).
Task 4: review Approved with 2 Important (triple-duplicated resolve loop in Connection#pipelined; duplicated ConnectionError construction) → fix round 1 dispatched (resume implementer), plus doc minors 3 (watch docs on wrong overload) and 4 (Client#multi doc omits AbortedError) folded in.
Task 4: minor (deferred): TxServer discards a partial frame on a TCP split (same fragility as slice 1 batching spec).
Task 4: minor (deferred): Client#push_handler not carried to the dedicated watch connection (property, not a ctor option; parity with Client#connect).
Task 4: minor (deferred): only db forwarding is spec-asserted for Client#watch's dedicated connection.
Task 4: fix round 1/5 (4 addressed, 0 open — fail_futures forall T helper; connection_error factored; watch docs on real overload; multi doc lists AbortedError; commits 11343d9ea..e0094a4e1)
Task 4: complete (commits 11ebabae5..e0094a4e1, review clean)
Task 5: Ruling: implementer made bare unsubscribe/punsubscribe await exactly one frame to match the brief's fake server; REJECTED — the fake server is the plan defect (real Redis sends one frame per subscribed channel, or a single nil frame when none). Brief formula `count == 0 ? 1 : count` restored; PubSubServer must track subscriptions per connection and answer like Redis — cost if wrong: none (matches Redis source pubsub.c).
Task 5: pre-review fix dispatched (resume implementer) before the task review.
Task 5: complete (commits e0094a4e1..827a8e218, review clean; Approved, 0 Important)
Task 5: Ruling: the following Task 5 minors are folded into Task 6 (same file, cheap, and the deprecation warnings make spec output non-pristine): (1) `Time.monotonic` → `Time.instant` in subscriber_spec (deprecation warnings); (2) drop the `# <path>` first-line comments in subscriber.cr and subscriber_spec.cr; (3) `control`: pop the Ack if `c.send` raises; (4) `read_loop`: only `"PONG"` confirms, any other String is a ProtocolError; (5) a top-level `CommandError` reply raises that error as the drop cause instead of ProtocolError; (6) a raising hook must not clobber the recorded network cause (`@error ||= ex`); (7) `on_disconnect` receives the recorded cause (`@error`) when a caller-side timeout already dropped the connection; (8) replace the `sleep 20.milliseconds` flake in "each iterates until close" with a `ping` after the second publish (pong is ordered after the message on the wire, so the message is in the channel when ping returns) — cost if wrong: a few lines of rework in one file.
Task 5: minor (deferred): four near-duplicate channel/pattern method pairs (control_set helper possible, brief-mandated shape).
Task 5: minor (deferred): no pending_redis live example for Subscriber in this task (Task 7 adds them).
Task 5: minor (deferred): `wait_until` helper unused until Task 6.
Task 6: Ruling: fold-in item 6 (`@error ||= ex` on a raising hook) WITHDRAWN — it contradicts the brief's spec "a hook that raises closes the subscriber" (error.message == "hook failed"); the hook exception is the reason the subscriber closed and stays the recorded error — cost if wrong: the original network cause is not retrievable after a hook failure (it was passed to the hook itself).
Task 6: complete (commits 827a8e218..7f7712db5, review clean; Approved, 0 Important)
Task 6: Ruling: fold two minors into Task 7 (one-liners in subscriber.cr): `return if @closed` before `on_reconnect` fires (close racing the install) and a `ping` doc sentence saying it is a no-op while reconnecting — cost if wrong: two lines.
Task 6: minor (deferred): no spec for "fresh socket dies during resubscribe" or on_reconnect raising.
Task 6: minor (deferred): args-array idiom written three times (control, resubscribe×2); send_control helper possible.
Task 7: review Approved with 1 Important (ping doc sentence's "like the other control commands" clause is wrong; controller-dictated wording) → fix round 1 dispatched (resume implementer).
Task 7: minor (deferred): live multi example uses a loose /WRONGTYPE|ERR/ regex (plan-mandated); could assert code "ERR".
Task 7: fix round 1/5 (1 addressed, 0 open — ping doc reworded; commits 672d0db0d..a7960c172)
Task 7: complete (commits 7f7712db5..a7960c172, review clean)
Task 8: complete (commits a7960c172..449e9ab43, review clean; std_spec 18845 ex, 14 known env failures, 0 under spec/std/redis; Redis suite 220/0/1 pending)
Final review (fable, c707e2309..449e9ab43): "With fixes". Important: (1) hooks run on the reader fiber; calling subscribe/unsubscribe/ping/receive from a hook deadlocks — document + optional reader-fiber guard; (2) reconnect_loop's install rescue `ConnectionError` too narrow for TLS (OpenSSL::SSL::Error on first write escapes and permanently closes a reconnect: true subscriber) — widen to `Error | IO::Error | OpenSSL::SSL::Error`. Folded minors: (3) pipelined docs on Client/Connection mention multi's raw OK/QUEUED/EXEC elements; (5) document read_timeout × slow-consumer interaction; spec section 4 text updated to say ScriptCache has its own mutex. Deferred per triage: minors 4,6,7,8,9,10 and all earlier deferred minors (none must be fixed before merge).
Final review: minor (deferred): failed reconnect attempts do not update `error` (getter doc slightly overpromises).
Final review: minor (deferred, slice 1 origin): Connection#send/read/pipeline only map IO::Error, not OpenSSL::SSL::Error — slice 3 item.
Final review: minor (deferred): "records a subscribe made while disconnected" spec relies on acting within the 100 ms first backoff.
Final review: minor (deferred): watch spec does not assert WATCH precedes the block's GET.
Final review: minor (deferred): ExecFuture#fail_all overwrites queue-time errors on nil/size-mismatch (unreachable against Redis).
Final review: fix wave pending Task 9 completion (compiler contention).
Task 9: benchmarks DONE (harness only, no commit). pubsub RTT median 77.2 µs vs redis-rs 99.3 vs go-redis 94.1 (p99 93.5/114.7/107.2); subscriber throughput 1.09M vs 1.10M vs 1.20M ops/s (Crystal single-threaded, not apples-to-apples); pipeline 10 INCR 84.8 µs vs multi 86.6 (+2.2%, client share +1.22 µs = 1.4%) — TARGET MET; evalsha 80.0 vs run 80.2 (+0.3%) — TARGET MET. futures-util pinned =0.3.32 (index gap).
Final fix wave dispatched at 449e9ab43.
Task 9: complete (harness only, review Approved; write-up minors: mixed baselines in the "+1.4% client" figure (conclusion unchanged), "identical bytes" control uses key "hand" vs "tx", "ScriptCache lookup" is an add, ratio header mislabeled, leftover "bench" subscription and Rust .ignore() in case 2 undisclosed — all README prose, gitignored; fix at leisure)
Final fix wave: 5/5 addressed, no new breakage (commits 449e9ab43..3c56f2e5c). Out-of-scope notes (deferred): kill_next spec may exercise the read path rather than the widened rescue; empty multi block contributes zero raw elements (doc implies MULTI+EXEC); a hook can still block via `sub.messages.receive` directly; guard precedes the closed check in control.
Branch redis-slice2 final HEAD 3c56f2e5c — ready for finishing-a-development-branch.
