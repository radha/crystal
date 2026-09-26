# SortedMap / SortedSet design: 2026-09-26

Tier 5 of the batteries roadmap. `require "sorted_map"` gives `SortedMap(K, V)`
and `require "sorted_set"` gives `SortedSet(T)`. Both sit on one B-tree
modeled on Rust's `BTreeMap`.

## User decisions

| question | decision |
|---|---|
| Names | `SortedMap` / `SortedSet` (named for what they do, not how; the B-tree is an implementation detail) |
| Ordering | `K#<=>` only, with no comparator block, so comparisons inline. For a custom order, wrap the key in a type whose `<=>` implements it. A `nil` comparison (NaN) raises `ArgumentError` |
| First cut scope | core map ops, navigation, range iteration, bulk build, set algebra (all four) |
| Performance bar | within ~1.5× of Rust `BTreeMap` at 1K/100K/1M keys (met, see the harness README) |

## Structure

- `SortedMap::Node(K, V)`: a leaf with `@len`, `StaticArray(K, 11)` keys and
  `StaticArray(V, 11)` values. `SortedMap::Internal(K, V) < Node` adds
  `StaticArray(Node, 12)` edges. Capacity 11 and minimum length 5 match
  Rust (B = 6).
- The map keeps `@root`, `@height` and `@size`. Leaves are at depth
  `@height`, so a node's kind follows from its level and internal nodes
  are reached with `unsafe_as` rather than a type check. Methods defined
  only on `Node` are not dispatched (checked in the LLVM IR).
- There is no parent pointer. Insert and delete recurse, which is bounded by
  the height. Cursors keep the path on the stack
  (`StaticArray(Node, 32)` + `StaticArray(Int32, 32)`, enough for
  2 × 6³¹ keys), so seeking and stepping never allocate.
- Slots at or past `len` are cleared (`Pointer#clear`), so the GC does not
  keep removed keys and values alive.
- Explicitly typed ivar declarations put `@len` at offset 4 (the type id's
  padding). Declared through its initializer, Crystal placed it after both
  arrays at offset 184.

## Algorithms

- **Insert:** bottom-up split. A full node splits at index 5 (5 keys
  left, the middle key moves up, 5 right) and the new key goes to the side
  it belongs on. A root split grows the tree.
- **Delete:** a key in an internal node is swapped with its predecessor
  (the largest key of the left subtree, always in a leaf). On the way back
  up, an underfull child borrows from a sibling with more than 5 keys, or
  merges with one. An empty internal root collapses.
- **shift / pop:** `remove_edge` walks the leftmost or rightmost path and
  rebalances on the way up.
- **floor / ceiling / lower / higher:** one descent that keeps the best
  candidate (`closest`).
- **Iteration:** a cursor with two position conventions. Forward keeps the
  next key's index at each ancestor level. Backward keeps that index minus
  one. Block forms loop over a leaf's keys directly and only step the
  cursor between leaves.
- **Bulk build (`from_sorted`, `new(enumerable)`, set algebra):** a
  `Builder` fills nodes to capacity along the right spine, opening a
  fresh chain of empty nodes below the lowest ancestor with room. At the
  end it tops up each short node on the right border from its full left
  sibling (`steal_left` with a count). Runs in O(n). Adjacent equal keys:
  the last value wins. `new(enumerable)` sorts stably first, so the last
  duplicate wins as with `Hash`.
- **Set algebra:** merge walks over two iterators, feeding the builder.
  O(n + m), and the output is always a valid, dense tree.

## Semantics

- Keys are the same key when `<=>` returns 0 (`==` is not consulted).
- Changing the map during iteration is memory safe: every step
  re-checks lengths against the live nodes (`ascend_forward`,
  `ascend_backward`, `Cursor#revalidate` before an external iterator
  reads). The iteration may then skip or repeat entries. Found by a
  fuzzer: the first version of `EntryIterator` read a cleared slot after a
  delete shrank its leaf.
- API: `[]`, `[]?`, `[]=`, `fetch`, `has_key?`, `has_value?`,
  `put_if_absent`, `delete`, `delete_range`, `first(?)`, `last(?)`,
  `first_key(?)`, `last_key(?)`, `shift(?)`, `pop(?)`, `floor`,
  `ceiling`, `lower`, `higher` (plus `_key` forms), `each` /
  `reverse_each` with or without a range (block and iterator forms),
  `each_key`, `each_value`, `keys`, `values`, `to_a`, `==`, `hash`,
  `dup`, `clone`, `clear`, `to_s`, `inspect`, `pretty_print`, plus the
  `SortedMap{k => v}` literal.
- `SortedSet(T)` wraps `SortedMap(T, Nil)` (`StaticArray(Nil, 11)` takes
  no space) and adds `add`, `<<`, `add?`, `concat`, `includes?`, `|`, `&`,
  `-`, `^`, `subset_of?`, `proper_subset_of?`, `superset_of?`,
  `proper_superset_of?`, `intersects?`, plus the `SortedSet{...}` literal.

## Verification

- `spec/std/sorted_map_spec.cr` and `sorted_set_spec.cr`: 60 examples,
  including Hash- and Set-mirrored random runs, every bulk size 0..400,
  every navigation probe against a linear scan, 300 random ranges both
  ways, and mutation during iteration. `check_invariants` (:nodoc:)
  checks key order, subtree bounds, node lengths and the size.
- Scratch fuzzers (not committed): 11 seeds × 300-600 rounds of mixed ops
  with invariants and ranges checked, all bulk sizes 0..3000, and String
  keys changed during block and iterator walks with forced GCs.

## Second round (same day)

- **delete_range by split and join.** Ranges of more than 32 keys are cut
  out with `split_node` at each end: an O(height) walk that moves the
  suffix of each node on the path into a new right node. Then
  `fix_right_border` / `fix_left_border` repair the cut edges top-down.
  Each short border node is topped up from its sibling, or merged with it
  when the two fit in one node. Internal nodes are topped up to MIN_LEN + 1
  so that merging one level down cannot underflow them. `count_keys`
  sizes the middle, and `join` concatenates the outer trees. `join` pops
  the left tree's largest key as separator, then either concatenates two
  roots of equal height or hangs the shorter tree off the other's spine
  (`append_right` / `append_left`), merging or balancing with the
  neighbour and splitting upward if needed. The rebalancing primitives
  (`shift_left`, `shift_right`, `concat`) no longer need a shared parent.
  A branch-coverage-instrumented fuzzer hit every join and fix branch.
  About 150K checked range deletions across 31 seeds.
- **Split point as in Rust** (index 4/5/6 by insert position).
- **JSON/YAML** as opt-in `sorted_map/json`, `sorted_map/yaml`,
  `sorted_set/json`, `sorted_set/yaml` (the `uuid/json` pattern).

## Deviations and follow-ups

- No comparator block (a user decision).
- Capacity is fixed at 11 regardless of `sizeof(K)`.
- A 1M bulk build is 1.2-1.7x Rust, from fresh-memory cost (a node arena
  would be the fix).
- No public `split_off` / `append` yet. The machinery exists
  (`split_node` + border fixes + `join`), so exposing it is small.
