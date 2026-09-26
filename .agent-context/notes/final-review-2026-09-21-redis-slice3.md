# Final whole-branch review: redis-slice3 (9f9b049d0..9a2932119)

Reviewed read-only: the full diff package, `src/redis/cluster.cr`, `src/redis/pool.cr`, `src/redis/crc16.cr` in full; the diffs of `client.cr`, `connection.cr`, `pipeline.cr`, `transaction.cr`, `error.cr`, `redis.cr`; the relevant bodies of `Client#wait`/`read_loop`/`disconnect`/`subscriber`, `Transaction`, `Future#value`; every new/changed spec file and `spec/support/redis.cr`; the spec, plan (Global Constraints, self-review notes) and the ledger. No suites were run; no working-tree mutation.

### Strengths

- **Spec coverage is complete.** Every §2–§6 item is present: CRC16/`key_slot`/`route_key` with the exact `KEYLESS`/`SPECIAL` tables; `Cluster` with the redirect loop, lazy coalesced reload, node-split concurrent pipelines, `multi`, `with_connection`, `watch`, `subscriber`, `nodes`, `refresh`, `close`; `Pool`; `Client#with_connection` and pooled `watch`; `Connection#watching?`; TLS error mapping; the two new errors. The three plan deviations (future API split, `pipeline_raw` yielding `(i, value, error)`, public `node_for`) are recorded and justified. No slice 1/2 public signature changed (`Pipeline#resolve` narrowing and `AbstractFuture` are `:nodoc:`; `Client.new` only gains a keyword).
- **`install` is genuinely parse-then-swap** (`cluster.cr:687-746`): the whole reply is reduced to plain `Described` tuples before the single `@mutex` section touches any `Node`; a malformed reply leaves the topology untouched (spec at `cluster_spec.cr:325`). First-wins master roles across ranges are handled.
- **Lock ordering is sound.** `@refresh_mutex` → (`load_topology` → I/O → `install` → `@mutex`) is the only nesting; `@mutex` is never held across I/O, never held while taking `@refresh_mutex`, and all node closes happen outside it. `Client#pool` builds the pool under the client mutex with no I/O, and `Client#close` closes it outside. No cycle exists among Cluster, Client, Pool and Connection mutexes.
- **`Pool` permit accounting is correct on every path** (`pool.cr:70-115`): no permit taken on the pre-check or timeout, returned on closed-under-mutex and on `open` failure, returned in `checkin` after the mutex, and the `send` under the mutex cannot block (capacity == size, one permit just consumed).
- **`pipelined` cannot leak a fiber or drop a reply**: `run_group` never raises (`rescue Exception`, stale flagged only for connection classes), every spawned fiber hits `wg.done` in `ensure`, delivered replies are kept and only the unreached tail is back-filled (`cluster.cr:452-468`). The partial-failure regression spec (`cluster_spec.cr:514`) pins this.
- **`Connection#watching?` rule is right**: cleared only when a `multi` actually sent bytes (Redis discards watches on `EXEC` even when it answers `EXECABORT`), so pooled `watch` never leaks a watch to the next borrower and pays no `UNWATCH` when `EXEC` ran (`transaction_spec.cr:393-403`).
- **Fake-cluster specs assert real behaviour** (order of commands per node, one write per node, `ASKING` contiguity, exact reload counts) and are deterministic under the default scheduler; the "coalesces" example was reworked so its assertion does not depend on how many round-one reloads the scheduler let through. The live helper cannot leave processes (`at_exit` + `stop` on configure failure) and produces no output.
- Documentation: module doc updated, class docs on `Cluster`, `Node`, `Pool`, third-person doc comments on every public method except one (see Minor).

### Issues

#### Critical (Must Fix)

None found.

#### Important (Should Fix)

1. **`Node#close` nils the client, so a fiber that already holds the `Node` recreates a `Client` after the node (or the whole cluster) was closed; that client is never closed** — `src/redis/cluster.cr:184-187` with `:170-173`. Reachable paths: (a) `execute`'s `TRYAGAIN` branch sleeps up to 500 ms (`:560`) and then calls `node.client` again with no `check_open`; a concurrent `Cluster#close` in that window yields a brand-new `Client` that connects, runs the command against a "closed" cluster, and leaks its socket and reader fiber. (b) A `Node` returned by `route`/`node_at` that a concurrent `install` puts in `gone` or `demoted` (`:744-745`): the holding fiber's next `node.client` recreates a client on an object no longer in `@nodes`, so `Cluster#close` can never reach it. (c) `pipelined`'s group fibers call `node.client` after `check_open` already passed (`:459`). This is also the root of ledger deferred minors "install: a node_at insertion in between is closed" and "load_topology/install/Node#client do not check closed". Fix: give `Node` a closed flag set by `close` that makes `client` raise `ConnectionError("node closed")` instead of re-creating; `install` reopens a retained node it lists as master (reset the flag), and `gone` nodes stay closed. Alternatively have the factory (`:669`) check the cluster's `@closed`, which covers (a)/(c) but not (b).

2. **`Node#client` is created outside any mutex** — `src/redis/cluster.cr:172`, versus spec §3.1 "created on first use under the cluster's mutex". `Client.new` has no yield point, so this is benign under the default scheduler, but it is a plain data race under `-Dpreview_mt` (two clients, one leaked) and every other shared field in the file is guarded. A per-`Node` `Mutex` (or the closed-flag fix above with a mutex) closes it in three lines.

3. **A pipeline with N `MOVED` replies performs about N topology reloads** — `src/redis/cluster.cr:349-362` with `:531-555`. Each retry calls `execute(slot, value)`, whose `route(slot)` runs `refresh_if_stale` and whose pending-`MOVED` handling then sets `@stale = true` again (`:553`), so the next retried command in the same loop reloads before *its* redirect is even looked at. During a resharding (exactly when many commands of one pipeline move) a 300-command pipeline can issue tens or hundreds of `CLUSTER SLOTS` round trips, serialized under `@refresh_mutex`, stalling every other fiber's routing. The `route(slot)` lookup is only needed for a pending `TRYAGAIN`: for a pending `MOVED`/`ASK` the node comes from `parse_redirect`. Fix: when `redirect` is `MOVED`/`ASK`, skip `route` (keep `check_open`), or defer marking stale until the retry loop has finished (one reload after the pipeline). The single-command `call` path is unaffected.

4. **`Client#watch`'s `ensure` can replace the block's exception** — `src/redis/client.cr:313-322`. `conn.unwatch` in the `ensure` does a round trip; if it raises `ConnectionError` (server gone) while the block raised something else (e.g. `AbortedError`, `CommandError`), the caller sees the `UNWATCH` failure and loses the original. The retry loop in the doc comment (`rescue Redis::AbortedError`) then does not fire. Wrap the `unwatch` in a `rescue ConnectionError` (the connection is closed by then and the pool drops it anyway), or unwatch only on the non-raising path and let a raising path leave with `watching?` set plus a documented `close`.

#### Minor (Nice to Have)

1. `src/redis/cluster.cr:189` — `Node#to_s` is public and has no doc comment (global constraint: every public method documented). Same line family: `command(*args, key:)` at `:274` lacks a `: Value` return restriction that its sibling `call` has.
2. `src/redis/cluster.cr:489-491` — `nodes` omits a master learned from a `MOVED` (`node_at`, `:600`) until the next reload, so `node_for(key)` can return a `Node` that `nodes` does not list. The doc ("as the last topology load reported") is technically accurate; a half sentence would save a reader the surprise.
3. `src/redis/cluster.cr:478-485` — `scan_each` on a map with no masters yields nothing instead of raising `ClusterError` like `route` does (ledger deferred). One `raise if masters.empty?` under the existing `synchronize` would align it.
4. `src/redis/cluster.cr:573-581` — `ask` re-implements `Client#call_raw(asking: true)` for the `args` form (ledger deferred). Encoding the args once with `RESP.write_command` into a slice and calling `call_raw` would drop the duplicate and the second code path through `pipelined`.
5. `src/redis/cluster.cr:584-595` — `parse_redirect` handles `::1:6381` correctly via `rindex(':')`, but nothing exercises IPv6 anywhere (redirect, `CLUSTER SLOTS`, `node_uri`); `URI.new(host: "::1")` and `Connection`'s use of `uri.host` should be checked once before anyone runs this against an IPv6 cluster. Not a spec requirement; noting for the backlog.
6. `src/redis/client.cr:346-348` — `with_connection` doc hardcodes "five seconds" and `Client` exposes no way to change the pool's `checkout_timeout` (spec §4.2 adds only `pool_size`). Fine per spec; a spec follow-up rather than a code fix.
7. `spec/std/redis/cluster_spec.cr:29` / `cluster_live_spec.cr:4` — `values` helper duplicated (ledger); a `RedisSpec.values` in the support file would remove both copies (and the one in `transaction_spec.cr`).
8. Coverage gaps worth one example each (ledger): `TRYAGAIN` inside a pipeline, an exhausted-redirect command inside a pipeline (`failures[i] = ClusterError`, other futures kept), a keyless-only pipeline, a `multi` whose first key is nil.

### Deferred-minor triage

| Ledger line | Verdict | Reason |
|---|---|---|
| T1: cluster.cr placeholder class doc | resolved | Task 7 wrote the full class doc (`cluster.cr:2-35`). |
| T2: `QueuedFuture#fail` comment not its own `:nodoc:` | leave deferred | Class is `:nodoc:`; matches sibling `resolve`. |
| T4: double / foreign checkin undetected | leave deferred | Spec §4 rules it out explicitly and the doc says so. |
| T4: module doc mentions Pool only at Task 10 | resolved | `src/redis.cr:56-58` now covers Pool and with_connection. |
| T5: with_connection doc hardcodes "five seconds" | leave deferred | Minor 6; spec-bound, needs a spec change to expose `checkout_timeout`. |
| T5: `close` local `pool` shadows private `pool` | leave deferred | Readability only; compiles and is correct. |
| T6: `pipeline_raw` rescue catches a block's `IO::TimeoutError` | leave deferred | No caller raises from the block; both in-tree blocks only assign. |
| T6: `call_raw` discards an error reply to `ASKING` | leave deferred | Plan-mandated; `ASKING` is a fixed no-arg command and the following command's own reply still surfaces. |
| T7: empty-host redirect resolves to seed 0's host | leave deferred | Real servers send concrete hosts (spike-verified); would only matter with `cluster-announce-ip` misconfiguration. |
| T7: `Cluster#ask` duplicates `call_raw(asking:)` | leave deferred | Minor 4; cosmetic. |
| T7: `install` swap vs. concurrent `node_at` insertion closed | **fix before merge** | Same root cause as Important 1: the fiber that created that node then recreates a client that nobody closes. Fixed by the same closed-flag change. |
| T7: `load_topology`/`install`/`Node#client` do not check closed | **fix before merge** | Important 1 (a)/(c): a client recreated after `Cluster#close` leaks a socket and reader fiber. |
| T7: `scan_each` yields nothing on a master-less map | leave deferred | Minor 3; one-liner, no data risk. |
| T7: `@stale`/`@closed` read unlocked | leave deferred | Documented advisory pattern shared with `Client` and `Pool`. |
| T7: class doc example uses pipelined/multi before Task 8 | resolved | Task 8 landed both. |
| T7: `command(*args, key:)` no return type; `Node#to_s` undocumented | **fix before merge** (doc only) | `Node#to_s` violates the "every public method documented" constraint; the return restriction is a one-token polish to do in the same edit. |
| T7: `tried` compares host strings | leave deferred | One extra probe on an odd seed list; harmless. |
| T7: FakeCluster answers any `CLUSTER` subcommand with the slots reply | leave deferred | No spec sends another subcommand; support-file convenience. |
| T7: `load_topology` no fall-through on `ProtocolError` | leave deferred | Deliberate and tested (`cluster_spec.cr:325`); surfacing a malformed reply is the safer behaviour. |
| T7: no spec for master-in-one-range/replica-in-another | leave deferred | Code trace is straightforward (`is_master ||= previous[:master]`); worth one example later. |
| T8: `ProtocolError` from a malformed redirect in the retry phase leaves futures unresolved | leave deferred | Identical to `Client#pipelined` when `ensure_connected` raises before sending: `Future#value` reports "pipeline not executed yet", which is accurate. |
| T8: redirect retries inside a pipeline are sequential | leave deferred (but see Important 3) | Sequential is acceptable; the reload cascade is the real cost. |
| T8: exception between yield and resolve leaves futures unresolved | leave deferred | Same consistency argument as above. |
| T8: `key_slot` under `@mutex`; unsized `IO::Memory` | leave deferred | Sub-microsecond; benchmark harness reported the split overhead within target. |
| T8: `values` helper duplicated | leave deferred | Minor 7. |
| T8: missing TRYAGAIN / exhausted / keyless-only / nil-first-key pipeline examples | leave deferred | Minor 8; the code paths are exercised indirectly (`execute` is shared with `call`). |
| T9: live helper port range requirement | leave deferred | Falls to pending, never fails. |
| T9: cluster spawned once per spec process (~1.5 s) | leave deferred | Acceptable cost, pending when no binary. |
| T9: spawn failure deletes node logs | leave deferred | Diagnostic convenience only. |
| T9: TOCTOU between probe and bind | leave deferred | Bind failure surfaces as a pending reason, not a false pass. |
| T9: `wait_for` connections opened outside `ensure` | leave deferred | Spec-process lifetime only. |
| T9: `values` in two spec files | leave deferred | Minor 7. |
| T9: `key_slot(keys[0])` computed twice in `watch` | leave deferred | Two CRC16s of a short key. |
| T9: `receive_within` surfaces `Channel::ClosedError` on a closed subscriber | leave deferred | Diagnostic only; the example fails either way. |

### Recommendations

1. Land Important 1 and 2 together as one small change to `Node`: a `@closed` flag and a `Mutex` around `client`, `close` setting the flag, `install` clearing it for retained masters. Add one fake-cluster example: `TRYAGAIN` answered by the fake, `cluster.close` from another fiber during the backoff, assert the second attempt raises `ConnectionError` and `fake.accepted(n)` does not grow.
2. For Important 3, the minimal change is in `execute`: `node = redirect && redirect.code != "TRYAGAIN" ? parse_redirect(redirect)[1] : route(slot)` (still `check_open` first), and process the pending redirect's slot patch as today. Add the example "pipeline with three MOVED replies reloads once" (count `slots_calls`).
3. Important 4: `conn.unwatch rescue nil`-style handling scoped to `ConnectionError`, plus a spec where the fake closes the socket on `UNWATCH` and the block's own exception is the one raised.
4. Fold Minor 1 into the same commit (doc on `Node#to_s`, `: Value` on `command`).
5. Everything else stays deferred; carry Minor 5 (IPv6) and Minor 6 (`checkout_timeout` on `Client`) into the slice 4 spec backlog.

### Assessment

**Ready to merge?** With fixes

**Reasoning:** The branch implements the whole slice 3 spec with sound locking, correct permit accounting and no dropped replies or leaked fibers in the pipeline path; the one real defect family is `Node` lifecycle (a client recreated after close/reload leaks a socket) plus the reload cascade on multi-`MOVED` pipelines, all of which are small, local fixes with obvious regression examples.
