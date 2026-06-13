struct Slice(T)
  # `partial_insertion_sort!` gives up after moving this many elements.
  private PARTIAL_INSERTION_LIMIT = 8

  protected def self.intro_sort!(a, n)
    return if n < 2
    quick_sort_for_intro_sort!(a, n, (n.bit_length - 1) * 2, true)
    insertion_sort!(a, n)
  end

  # *leftmost* is true while `a` is still the start of the original range, so
  # that `a[-1]` (the ancestor pivot of the equal-element optimization below)
  # may not be dereferenced.
  protected def self.quick_sort_for_intro_sort!(a, n, d, leftmost)
    while n > 16
      if d == 0
        heap_sort!(a, n)
        return
      end
      d -= 1
      median_to_front!(a, n)

      # Equal-element optimization (pdqsort): when the ancestor pivot at `a[-1]`
      # is not less than this pivot, every element here equal to the pivot sorts
      # ahead of the rest. Partition them to the front and recurse only on the
      # remainder, giving O(n log k) on inputs with k distinct values.
      if !leftmost && cmp((a - 1).value, a.value) >= 0
        le_pos = partition_left!(a, n)
        skipped = (le_pos - a).to_i32 + 1
        a += skipped
        n -= skipped
        next
      end

      pivot_pos, already_partitioned = partition_right!(a, n)
      l_size = (pivot_pos - a).to_i32
      r = pivot_pos + 1
      r_size = n - l_size - 1
      # A decently balanced partition that was already partitioned (needed no
      # swaps) suggests the range is mostly sorted; attempt a bounded insertion
      # sort on both halves and skip recursing if both end up fully sorted.
      if already_partitioned && l_size >= n // 8 && r_size >= n // 8 &&
         partial_insertion_sort!(a, l_size) && partial_insertion_sort!(r, r_size)
        return
      end
      quick_sort_for_intro_sort!(r, r_size, d, false)
      n = l_size
    end
  end

  protected def self.heap_sort!(a, n)
    (n // 2).downto 0 do |p|
      heapify!(a, p, n)
    end
    while n > 1
      n -= 1
      a.value, a[n] = a[n], a.value
      heapify!(a, 0, n)
    end
  end

  protected def self.heapify!(a, p, n)
    v, c = a[p], p
    while c < (n - 1) // 2
      c = 2 * (c + 1)
      c -= 1 if cmp(a[c], a[c - 1]) < 0
      break unless cmp(v, a[c]) <= 0
      a[p] = a[c]
      p = c
    end
    if n & 1 == 0 && c == n // 2 - 1
      c = 2 * c + 1
      if cmp(v, a[c]) < 0
        a[p] = a[c]
        p = c
      end
    end
    a[p] = v
  end

  # Orders so that `x.value <= y.value`.
  protected def self.sort2!(x : Pointer(T), y : Pointer(T)) forall T
    if cmp(y.value, x.value) < 0
      x.value, y.value = y.value, x.value
    end
  end

  # Places the median of `a[0]`, `a[n // 2]` and `a[n - 1]` at `a[0]` (the
  # pivot for `partition_right!`), leaving the smallest of the three at the
  # middle and the largest at `a[n - 1]`. The latter two then act as sentinels
  # that bound the partition's left and right scans without explicit checks.
  protected def self.median_to_front!(a, n)
    mid, last = a + n // 2, a + n - 1
    sort2!(mid, a)
    sort2!(a, last)
    sort2!(mid, a)
  end

  # Partitions `a[0...n]` around the pivot held at `a[0]` (placed there by
  # `median_to_front!`): every element less than the pivot ends up before it
  # and every element not less than it after, with the pivot moved to its final
  # resting place. Returns that pivot position and whether the range was already
  # partitioned (no element had to be moved).
  #
  # This is pdqsort's partition (by Orson Peters): a median-of-three pivot at
  # the front, the smallest and largest of the three left as sentinels that
  # bound the two scans, and the pivot excluded from the recursion. A branchless
  # block variant (BlockQuicksort, Edelkamp & Weiss) was also implemented and
  # benchmarked but rejected: in Crystal it only paid off on large
  # high-entropy inputs while regressing the common nearly-sorted and reversed
  # cases by up to ~1.9x, as the per-element offset bookkeeping outweighs the
  # branch mispredictions it avoids against an already tight scalar scan.
  protected def self.partition_right!(a : Pointer(T), n) forall T
    pivot = a.value
    first = a
    last = a + n

    # Find the first element not less than the pivot from the left (the pivot
    # value at `a[0]` and the largest-of-three sentinel at `a[n - 1]` bound this
    # scan), then the first element less than the pivot from the right.
    loop do
      first += 1
      break unless cmp(first.value, pivot) < 0
    end
    if first - 1 == a
      loop do
        break unless first < last
        last -= 1
        break if cmp(last.value, pivot) < 0
      end
    else
      loop do
        last -= 1
        break if cmp(last.value, pivot) < 0
      end
    end

    # If no element had to move the range was already partitioned, a signal the
    # caller uses to attempt a bounded insertion sort.
    already_partitioned = first >= last

    while first < last
      first.value, last.value = last.value, first.value
      loop do
        first += 1
        break unless cmp(first.value, pivot) < 0
      end
      loop do
        last -= 1
        break if cmp(last.value, pivot) < 0
      end
    end

    pivot_pos = first - 1
    a.value = pivot_pos.value
    pivot_pos.value = pivot
    {pivot_pos, already_partitioned}
  end

  # Partitions `a[0...n]` so that every element less than or equal to the pivot
  # at `a[0]` ends up before every greater element, moving the pivot to the
  # boundary and returning its final position. Used by the equal-element
  # optimization to gather (and then skip) the run of elements equal to the
  # pivot; a plain Hoare scan, as duplicate-heavy ranges are uncommon.
  protected def self.partition_left!(a : Pointer(T), n) forall T
    pivot = a.value
    first = a
    last = a + n

    loop do
      last -= 1
      break unless cmp(pivot, last.value) < 0
    end
    if last + 1 == a + n
      loop do
        break unless first < last
        first += 1
        break if cmp(pivot, first.value) < 0
      end
    else
      loop do
        first += 1
        break if cmp(pivot, first.value) < 0
      end
    end

    while first < last
      first.value, last.value = last.value, first.value
      loop do
        last -= 1
        break unless cmp(pivot, last.value) < 0
      end
      loop do
        first += 1
        break if cmp(pivot, first.value) < 0
      end
    end

    pivot_pos = last
    a.value = pivot_pos.value
    pivot_pos.value = pivot
    pivot_pos
  end

  protected def self.insertion_sort!(a, n)
    (1...n).each do |i|
      l = a + i
      v = l.value
      p = l - 1
      while l > a && cmp(v, p.value) < 0
        l.value = p.value
        l, p = p, p - 1
      end
      l.value = v
    end
  end

  # Insertion sort that gives up once more than `PARTIAL_INSERTION_LIMIT`
  # elements have been moved, returning `false` with the range partially
  # sorted (but still a permutation of its input).
  protected def self.partial_insertion_sort!(a, n)
    moves = 0_i64
    (1...n).each do |i|
      l = a + i
      v = l.value
      p = l - 1
      if cmp(v, p.value) < 0
        while l > a && cmp(v, p.value) < 0
          l.value = p.value
          l, p = p, p - 1
        end
        l.value = v
        moves += (a + i) - l
        return false if moves > PARTIAL_INSERTION_LIMIT
      end
    end
    true
  end

  protected def self.intro_sort!(a, n, comp)
    return if n < 2
    quick_sort_for_intro_sort!(a, n, (n.bit_length - 1) * 2, true, comp)
    insertion_sort!(a, n, comp)
  end

  protected def self.quick_sort_for_intro_sort!(a, n, d, leftmost, comp)
    while n > 16
      if d == 0
        heap_sort!(a, n, comp)
        return
      end
      d -= 1
      median_to_front!(a, n, comp)

      # Equal-element optimization (pdqsort); see the `<=>`-based overload.
      if !leftmost && cmp((a - 1).value, a.value, comp) >= 0
        le_pos = partition_left!(a, n, comp)
        skipped = (le_pos - a).to_i32 + 1
        a += skipped
        n -= skipped
        next
      end

      pivot_pos, already_partitioned = partition_right!(a, n, comp)
      l_size = (pivot_pos - a).to_i32
      r = pivot_pos + 1
      r_size = n - l_size - 1
      # A decently balanced partition that was already partitioned (needed no
      # swaps) suggests the range is mostly sorted; attempt a bounded insertion
      # sort on both halves and skip recursing if both end up fully sorted.
      if already_partitioned && l_size >= n // 8 && r_size >= n // 8 &&
         partial_insertion_sort!(a, l_size, comp) && partial_insertion_sort!(r, r_size, comp)
        return
      end
      quick_sort_for_intro_sort!(r, r_size, d, false, comp)
      n = l_size
    end
  end

  protected def self.heap_sort!(a, n, comp)
    (n // 2).downto 0 do |p|
      heapify!(a, p, n, comp)
    end
    while n > 1
      n -= 1
      a.value, a[n] = a[n], a.value
      heapify!(a, 0, n, comp)
    end
  end

  protected def self.heapify!(a, p, n, comp)
    v, c = a[p], p
    while c < (n - 1) // 2
      c = 2 * (c + 1)
      c -= 1 if cmp(a[c], a[c - 1], comp) < 0
      break unless cmp(v, a[c], comp) <= 0
      a[p] = a[c]
      p = c
    end
    if n & 1 == 0 && c == n // 2 - 1
      c = 2 * c + 1
      if cmp(v, a[c], comp) < 0
        a[p] = a[c]
        p = c
      end
    end
    a[p] = v
  end

  # Orders so that `comp.call(x.value, y.value) <= 0`.
  protected def self.sort2!(x : Pointer(T), y : Pointer(T), comp) forall T
    if cmp(y.value, x.value, comp) < 0
      x.value, y.value = y.value, x.value
    end
  end

  protected def self.median_to_front!(a, n, comp)
    mid, last = a + n // 2, a + n - 1
    sort2!(mid, a, comp)
    sort2!(a, last, comp)
    sort2!(mid, a, comp)
  end

  # As `partition_right!` above, using the comparator block. The initial scans
  # carry explicit bounds checks because a user comparator may be inconsistent
  # and so violate the sentinel guarantee that makes them unnecessary in the
  # `<=>`-based overload; an inconsistent comparator then yields an unspecified
  # order rather than reading out of bounds.
  protected def self.partition_right!(a : Pointer(T), n, comp) forall T
    pivot = a.value
    first = a
    last = a + n
    fin = a + n

    loop do
      first += 1
      break unless first < fin && cmp(first.value, pivot, comp) < 0
    end
    if first - 1 == a
      loop do
        break unless first < last
        last -= 1
        break if cmp(last.value, pivot, comp) < 0
      end
    else
      loop do
        break unless last > first
        last -= 1
        break if cmp(last.value, pivot, comp) < 0
      end
    end

    already_partitioned = first >= last

    while first < last
      first.value, last.value = last.value, first.value
      loop do
        first += 1
        break unless first < fin && cmp(first.value, pivot, comp) < 0
      end
      loop do
        break unless last > a
        last -= 1
        break if cmp(last.value, pivot, comp) < 0
      end
    end

    pivot_pos = first - 1
    a.value = pivot_pos.value
    pivot_pos.value = pivot
    {pivot_pos, already_partitioned}
  end

  # As `partition_left!` above; the scans carry bounds checks so an inconsistent
  # comparator yields an unspecified order rather than reading out of bounds.
  protected def self.partition_left!(a : Pointer(T), n, comp) forall T
    pivot = a.value
    first = a
    last = a + n

    loop do
      break unless last > first
      last -= 1
      break unless cmp(pivot, last.value, comp) < 0
    end
    loop do
      break unless first < last
      first += 1
      break if cmp(pivot, first.value, comp) < 0
    end

    while first < last
      first.value, last.value = last.value, first.value
      loop do
        break unless last > first
        last -= 1
        break unless cmp(pivot, last.value, comp) < 0
      end
      loop do
        break unless first < last
        first += 1
        break if cmp(pivot, first.value, comp) < 0
      end
    end

    pivot_pos = last
    a.value = pivot_pos.value
    pivot_pos.value = pivot
    pivot_pos
  end

  protected def self.insertion_sort!(a, n, comp)
    (1...n).each do |i|
      l = a + i
      v = l.value
      p = l - 1
      while l > a && cmp(v, p.value, comp) < 0
        l.value = p.value
        l, p = p, p - 1
      end
      l.value = v
    end
  end

  # Insertion sort that gives up once more than `PARTIAL_INSERTION_LIMIT`
  # elements have been moved, returning `false` with the range partially
  # sorted (but still a permutation of its input).
  protected def self.partial_insertion_sort!(a, n, comp)
    moves = 0_i64
    (1...n).each do |i|
      l = a + i
      v = l.value
      p = l - 1
      if cmp(v, p.value, comp) < 0
        while l > a && cmp(v, p.value, comp) < 0
          l.value = p.value
          l, p = p, p - 1
        end
        l.value = v
        moves += (a + i) - l
        return false if moves > PARTIAL_INSERTION_LIMIT
      end
    end
    true
  end

  protected def self.cmp(v1, v2)
    v = v1 <=> v2
    raise ArgumentError.new("Comparison of #{v1} and #{v2} failed") if v.nil?
    v
  end

  protected def self.cmp(v1, v2, block)
    v = block.call(v1, v2)
    raise ArgumentError.new("Comparison of #{v1} and #{v2} failed") if v.nil?
    v
  end

  # The stable sort implementation is a port of Rust's driftsort, by Orson
  # Peters and Lukas Bergdoll.
  # https://github.com/rust-lang/rust/tree/master/library/core/src/slice/sort/stable
  #
  # Design document:
  # https://github.com/Voultapher/sort-research-rs/blob/main/writeup/driftsort_introduction/text.md
  #
  # Rust License (MIT):
  #
  # Permission is hereby granted, free of charge, to any
  # person obtaining a copy of this software and associated
  # documentation files (the "Software"), to deal in the
  # Software without restriction, including without
  # limitation the rights to use, copy, modify, merge,
  # publish, distribute, sublicense, and/or sell copies of
  # the Software, and to permit persons to whom the Software
  # is furnished to do so, subject to the following
  # conditions:
  #
  # The above copyright notice and this permission notice
  # shall be included in all copies or substantial portions
  # of the Software.
  #
  # THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
  # ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
  # TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
  # PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
  # SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
  # CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
  # OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
  # IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
  # DEALINGS IN THE SOFTWARE.

  # Slices of up to this length get sorted using insertion sort; it is also
  # the length below which the stable quicksort switches to insertion sort.
  private STABLE_SMALL_SORT = 20

  # Above this length, pivot selection recursively computes a pseudomedian
  # of the approximate medians of three sections instead of a plain median
  # of 3.
  private PSEUDO_MEDIAN_REC_THRESHOLD = 64

  # Pre-sorted runs shorter than roughly sqrt(n) are not worth tracking, see
  # `drift_sort!`. For inputs of up to this threshold squared a constant
  # threshold capped by half the input length is used instead, so that
  # detection of fully or nearly sorted inputs keeps working.
  private MIN_SQRT_RUN_LEN = 64

  # The scratch buffer covers the whole input for inputs of up to this many
  # bytes, so that the entire slice can be quicksorted, and is scaled back to
  # `n - n // 2` (the longest span an unsorted logical run can reach) above
  # it.
  private STABLE_MAX_FULL_ALLOC_BYTES = 8_000_000

  # Driftsort, a hybrid of bottom-up mergesort and top-down stable quicksort.
  #
  # The slice is scanned left to right, forming logical runs: pre-existing
  # sorted runs of at least sqrt(n) elements are tracked as "sorted" runs,
  # anything else becomes an "unsorted" run whose elements are only sorted
  # (via stable quicksort) once the run has to be physically merged with a
  # sorted neighbor. Adjacent unsorted runs combine without doing any work,
  # so inputs with little pre-existing order get quicksorted in chunks as
  # large as the scratch space allows, which both has better constants than
  # merging and sorts inputs with k distinct values in O(n log k). The order
  # in which runs are merged follows powersort's heuristic.
  protected def self.stable_sort!(v : Slice(T)) forall T
    size = v.size
    return if size < 2

    if size <= STABLE_SMALL_SORT
      insertion_sort!(v.to_unsafe, size)
      return
    end

    # Fully ascending and descending inputs are common enough to deserve
    # finishing in n - 1 comparisons without allocating any scratch space.
    # The detected first run is handed down to `drift_sort!` so it is never
    # scanned twice.
    first_run_len, first_run_reversed = find_natural_run(v)
    if first_run_len == size
      v.reverse! if first_run_reversed
      return
    end

    scratch_len = Math.max(size - size // 2, Math.min(size, STABLE_MAX_FULL_ALLOC_BYTES // Math.max(sizeof(T), 1)))
    scratch = Pointer(T).malloc(scratch_len)

    # For small inputs quicksort is not yet beneficial: one or two
    # small-sorts plus a single merge outperform it, so sort runs eagerly.
    eager_sort = size <= STABLE_SMALL_SORT * 2
    drift_sort!(v, scratch, scratch_len, eager_sort, first_run_len, first_run_reversed)
  end

  # The main loop for driftsort: identifies logical runs and merges them in
  # the order given by powersort's heuristic. If `eager_sort` is true, only
  # small-sorts and physical merges are performed, ensuring O(n log n)
  # worst-case complexity. Fully ascending and descending inputs are sorted
  # with exactly n - 1 comparisons.
  #
  # A non-negative *first_run_len* hands in the already detected (but not
  # yet reversed) natural run at the start of `v`, saving a rescan.
  protected def self.drift_sort!(v : Slice(T), scratch : Pointer(T), scratch_len, eager_sort, first_run_len = -1, first_run_reversed = false) forall T
    size = v.size
    return if size < 2

    scale_factor = merge_tree_scale_factor(size)

    # It's important to have a relatively high entry barrier for pre-sorted
    # runs, as the presence of a single such run forces on average several
    # merge operations and shrinks the maximum quicksort size a lot.
    min_good_run_len =
      if size <= MIN_SQRT_RUN_LEN * MIN_SQRT_RUN_LEN
        Math.min(size - size // 2, MIN_SQRT_RUN_LEN)
      else
        sqrt_approx(size)
      end

    # Stack of logical runs (length and sorted flag), plus the desired depth
    # of the merge node between each run and its successor per powersort's
    # heuristic. The desired depths on the stack are strictly increasing and
    # `merge_tree_depth` is at most 64, so together with the initial dummy
    # run the capacity of 66 can never be exceeded.
    runs = uninitialized StaticArray(Tuple(Int32, Bool), 66)
    desired_depths = uninitialized StaticArray(Int32, 66)
    stack_len = 0

    scan_idx = 0
    prev_run_len = 0
    prev_sorted = true # Initial dummy run.

    loop do
      # Compute the next run and the desired depth of the merge node between
      # the previous and the next run. On the last iteration a dummy run with
      # root-level desired depth fully collapses the merge tree.
      if scan_idx < size
        next_run_len, next_sorted =
          if scan_idx == 0 && first_run_len >= 0
            adopt_run(v, first_run_len, first_run_reversed, min_good_run_len, eager_sort)
          else
            create_run(v[scan_idx, size - scan_idx], min_good_run_len, eager_sort)
          end
        desired_depth = merge_tree_depth(scan_idx - prev_run_len, scan_idx, scan_idx + next_run_len, scale_factor)
      else
        next_run_len, next_sorted = 0, true
        desired_depth = 0
      end

      # Process the merge nodes between earlier runs that desire to be deeper
      # in the merge tree than the merge node between the previous and next
      # run: pop the left neighbor run from the stack and merge it into the
      # previous run.
      while stack_len > 1 && desired_depths[stack_len - 1] >= desired_depth
        left_run_len, left_sorted = runs[stack_len - 1]
        merged_len = left_run_len + prev_run_len
        merge_start = scan_idx - merged_len
        prev_sorted = logical_merge!(v[merge_start, merged_len], scratch, scratch_len, left_run_len, left_sorted, prev_sorted)
        prev_run_len = merged_len
        stack_len -= 1
      end

      runs[stack_len] = {prev_run_len, prev_sorted}
      desired_depths[stack_len] = desired_depth
      stack_len += 1

      # Break before overriding the last run with the dummy run.
      break if scan_idx >= size

      scan_idx += next_run_len
      prev_run_len = next_run_len
      prev_sorted = next_sorted
    end

    unless prev_sorted
      stable_quicksort!(v, scratch, scratch_len)
    end
  end

  # Creates a new logical run over the start of `v`, returning its length
  # and whether it is sorted. A pre-existing run that clears the
  # `min_good_run_len` threshold is returned as a sorted run. Otherwise, if
  # `eager_sort` is true a freshly sorted run of up to `STABLE_SMALL_SORT`
  # elements is returned, and if it is false an unsorted run of up to
  # `min_good_run_len` elements.
  protected def self.create_run(v : Slice(T), min_good_run_len, eager_sort) forall T
    if v.size >= min_good_run_len
      run_len, was_reversed = find_natural_run(v)
      adopt_run(v, run_len, was_reversed, min_good_run_len, eager_sort)
    else
      adopt_run(v, 0, false, min_good_run_len, eager_sort)
    end
  end

  # Turns an already detected (not yet reversed) natural run at the start of
  # `v` into a logical run, applying `create_run`'s policy.
  protected def self.adopt_run(v : Slice(T), run_len, was_reversed, min_good_run_len, eager_sort) forall T
    size = v.size
    if run_len >= min_good_run_len
      v[0, run_len].reverse! if was_reversed
      return {run_len, true}
    end

    if eager_sort
      run_len = Math.min(STABLE_SMALL_SORT, size)
      insertion_sort!(v.to_unsafe, run_len)
      {run_len, true}
    else
      {Math.min(min_good_run_len, size), false}
    end
  end

  # Returns the length of the natural run at the start of `v`, and whether
  # that run is strictly descending - in which case reversing it is a stable
  # operation that sorts it.
  protected def self.find_natural_run(v : Slice(T)) forall T
    size = v.size
    return {size, false} if size < 2

    a = v.to_unsafe
    run_len = 2
    if cmp(a[1], a[0]) < 0
      while run_len < size && cmp(a[run_len], a[run_len - 1]) < 0
        run_len += 1
      end
      {run_len, true}
    else
      while run_len < size && cmp(a[run_len], a[run_len - 1]) >= 0
        run_len += 1
      end
      {run_len, false}
    end
  end

  # Merges the adjacent logical runs `v[0...mid]` and `v[mid...]`, returning
  # whether the combined run is sorted. Two unsorted runs that still fit the
  # scratch space simply combine into a bigger unsorted run, deferring the
  # work; otherwise any unsorted side is quicksorted and the two runs are
  # physically merged.
  protected def self.logical_merge!(v : Slice(T), scratch : Pointer(T), scratch_len, mid, left_sorted, right_sorted) forall T
    if v.size > scratch_len || left_sorted || right_sorted
      stable_quicksort!(v[0, mid], scratch, scratch_len) unless left_sorted
      stable_quicksort!(v[mid..], scratch, scratch_len) unless right_sorted
      merge!(v, mid, scratch)
      true
    else
      false
    end
  end

  protected def self.stable_quicksort!(v : Slice(T), scratch : Pointer(T), scratch_len) forall T
    # Limit the number of imbalanced partitions to `2 * floor(log2(len))`.
    limit = 2 * ((v.size | 1).bit_length - 1)
    stable_quicksort!(v, scratch, scratch_len, limit, Pointer(T).null)
  end

  # Sorts `v` recursively using stable quicksort, partitioning out-of-place
  # through the scratch space, which `v` must fit (unsorted logical runs are
  # never allowed to outgrow it). `ancestor_pivot` points at a copy of the
  # pivot of the most recent partition this call descended right of, if any:
  # every element of `v` then compares greater than or equal to it.
  protected def self.stable_quicksort!(v : Slice(T), scratch : Pointer(T), scratch_len, limit, ancestor_pivot : Pointer(T)) forall T
    raise "BUG: driftsort quicksort range exceeds the scratch space" if v.size > scratch_len

    loop do
      size = v.size

      if size <= STABLE_SMALL_SORT
        insertion_sort!(v.to_unsafe, size)
        return
      end

      if limit == 0
        # Too many bad pivots: switch to the O(n log n) fallback algorithm,
        # driftsort in eager mode (it then performs only small-sorts and
        # physical merges, and in particular never re-enters quicksort).
        drift_sort!(v, scratch, scratch_len, true)
        return
      end
      limit -= 1

      pivot = v.unsafe_fetch(choose_stable_pivot(v))

      # If the pivot is equal to our left ancestor pivot, all elements equal
      # to it sort before everything else in `v`: partition with
      # less-than-or-equal, putting them in front, and skip them entirely
      # instead of recursing on them. This gives O(n log k) sorting for k
      # distinct values, a strategy borrowed from pdqsort.
      equal_partition = !ancestor_pivot.null? && cmp(ancestor_pivot.value, pivot) >= 0

      num_lt = 0
      unless equal_partition
        num_lt = stable_partition!(v, scratch, pivot, 0)
        # A pivot that is the minimum of `v` also makes the less-than part
        # empty; the equal-partition pass is then what removes the pivot's
        # duplicates and guarantees progress.
        equal_partition = num_lt == 0
      end

      if equal_partition
        num_le = stable_partition!(v, scratch, pivot, 1)
        v = v[num_le..]
        ancestor_pivot = Pointer(T).null
        next
      end

      # Process the right side with recursion, the left side with the next
      # loop iteration.
      stable_quicksort!(v[num_lt..], scratch, scratch_len, limit, pointerof(pivot))
      v = v[0, num_lt]
    end
  end

  # Partitions `v` into the elements that compare less than (`bound = 0`) or
  # at most equal to (`bound = 1`) `pivot`, which end up in front, and the
  # rest at the back, both parts keeping their relative order: a stable
  # partition. Returns the size of the front part.
  #
  # The elements are partitioned out-of-place into the scratch space - the
  # front part filling it upwards from the bottom and the back part downwards
  # from the top - and then copied back, un-reversing the back part.
  protected def self.stable_partition!(v : Slice(T), scratch : Pointer(T), pivot : T, bound) forall T
    size = v.size

    scan = v.to_unsafe
    num_left = 0
    scratch_rev = scratch + size

    i = 0
    while i < size
      x = scan[i]
      towards_left = cmp(x, pivot) < bound
      # The branchless core: select the destination side and store, without
      # the value ever depending on a taken branch.
      scratch_rev -= 1
      dst = (towards_left ? scratch : scratch_rev) + num_left
      dst.value = x
      num_left += towards_left ? 1 : 0
      i += 1
    end

    # The front part goes back as is. The back part was filled top-down in
    # scan order, so copying it back in reverse restores its original
    # relative order.
    scan.copy_from(scratch, num_left)
    num_right = size - num_left
    dst = scan + num_left
    src = scratch + size - 1
    i = 0
    while i < num_right
      dst[i] = (src - i).value
      i += 1
    end

    num_left
  end

  # Selects a pivot from `v`, as an index, without mutating `v`. Algorithm
  # taken from glidesort by Orson Peters: an adaptive number of points is
  # sampled, approximating the quality of a median of sqrt(n) elements.
  protected def self.choose_stable_pivot(v : Slice(T)) forall T
    size = v.size
    base = v.to_unsafe
    len_div_8 = size // 8

    a = base                 # [0, n/8)
    b = base + len_div_8 * 4 # [4n/8, 5n/8)
    c = base + len_div_8 * 7 # [7n/8, n)

    median =
      if size < PSEUDO_MEDIAN_REC_THRESHOLD
        median3(a, b, c)
      else
        median3_rec(a, b, c, len_div_8)
      end
    (median - base).to_i32
  end

  # Calculates an approximate median of 3 elements from sections `a`, `b`,
  # `c`, or recursively from an approximation of each if they're large
  # enough. By dividing the size of each section by 8 when recursing this
  # samples f(n) = 3*f(n/8) -> O(n^(log(3)/log(8))) ~= O(n^0.528) elements.
  protected def self.median3_rec(a : Pointer(T), b : Pointer(T), c : Pointer(T), n) forall T
    if n * 8 >= PSEUDO_MEDIAN_REC_THRESHOLD
      n8 = n // 8
      a = median3_rec(a, a + n8 * 4, a + n8 * 7, n8)
      b = median3_rec(b, b + n8 * 4, b + n8 * 7, n8)
      c = median3_rec(c, c + n8 * 4, c + n8 * 7, n8)
    end
    median3(a, b, c)
  end

  # Calculates the median of 3 elements, as a pointer to it.
  protected def self.median3(a : Pointer(T), b : Pointer(T), c : Pointer(T)) forall T
    x = cmp(a.value, b.value) < 0
    y = cmp(a.value, c.value) < 0
    if x == y
      # If both false then b, c <= a, and we want to return max(b, c).
      # If both true then a < b, c, and we want to return min(b, c).
      # Toggling the outcome of b < c by x gives this behavior.
      z = cmp(b.value, c.value) < 0
      z != x ? c : b
    else
      # Either c <= a < b or b <= a < c, thus a is the median.
      a
    end
  end

  # Merges non-decreasing runs `v[..mid]` and `v[mid..]` using `buf` as
  # temporary storage (it must fit the shorter of the two runs), and stores
  # the result into `v[..]`.
  protected def self.merge!(v, mid, buf)
    size = v.size

    if mid <= size - mid
      # The left run is shorter.
      buf.copy_from(v.to_unsafe, mid)

      left = 0
      right = mid
      out = v.to_unsafe

      while left < mid && right < size
        # Consume the lesser side.
        # If equal, prefer the left run to maintain stability.
        if cmp(v[right], buf[left]) < 0
          out.value = v[right]
          out += 1
          right += 1
        else
          out.value = buf[left]
          out += 1
          left += 1
        end
      end

      out.copy_from(buf + left, mid - left)
    else
      # The right run is shorter.
      buf.copy_from((v + mid).to_unsafe, size - mid)

      left = mid
      right = size - mid
      out = v.to_unsafe + size

      while left > 0 && right > 0
        # Consume the greater side.
        # If equal, prefer the right run to maintain stability.
        if cmp(buf[right - 1], v[left - 1]) < 0
          left -= 1
          out -= 1
          out.value = v[left]
        else
          right -= 1
          out -= 1
          out.value = buf[right]
        end
      end

      (v + left).copy_from(buf, right)
    end
  end

  # Nearly-Optimal Mergesorts: Fast, Practical Sorting Methods That Optimally
  # Adapt to Existing Runs by J. Ian Munro and Sebastian Wild.
  #
  # This method forms a binary merge tree, where each internal node
  # corresponds to a splitting point between the adjacent runs that have to
  # be merged. If the array is visualized as the number line from 0 to 1, we
  # want to find the dyadic fraction with smallest denominator that lies
  # between the midpoints of the two to-be-merged slices. The exponent in the
  # dyadic fraction indicates the desired depth in the binary merge tree this
  # internal node wishes to have. This does not always correspond to the
  # actual depth due to the inherent imbalance in runs, but we follow it as
  # closely as possible.
  #
  # As an optimization we rescale the number line from [0, 1) to [0, 2^62).
  # Finding the simplest dyadic fraction between midpoints then corresponds
  # to finding the most significant bit difference of the midpoints. We save
  # `scale_factor = ceil(2^62 / n)` to perform this rescaling using a
  # multiplication, avoiding having to repeatedly do integer divides. This
  # rescaling isn't exact when n is not a power of two since we use integers
  # and not reals, but the result is very close, and in fact when n < 2^30
  # the resulting tree is equivalent as the approximation errors stay
  # entirely in the lower order bits.
  #
  # Thus for the splitting point between two adjacent slices [a, b) and
  # [b, c) the desired depth of the corresponding merge node is
  # CLZ((a+b)*f ^ (b+c)*f), where CLZ counts the number of leading zeros in
  # an integer and f is our scale factor. Note that we omitted the division
  # by two in the midpoint calculations, as this simply shifts the bits by
  # one position (and thus always adds one to the result), and we only care
  # about the relative depths.
  #
  # `x = (a+b)*f` does not overflow: with a < n and b <= n we get
  # `x < (2^62 / n + 1) * 2n = 2^63 + 2n`, which fits an unsigned 64-bit
  # integer for any valid slice size.
  @[AlwaysInline]
  protected def self.merge_tree_scale_factor(n : Int32) : UInt64
    ((1_u64 << 62) &+ n.to_u64 &- 1) // n.to_u64
  end

  # Note: output is < 64 when left < right as f*x and f*y must differ in some
  # bit, and is <= 64 always.
  @[AlwaysInline]
  protected def self.merge_tree_depth(left, mid, right, scale_factor : UInt64) : Int32
    x = left.to_u64 &+ mid.to_u64
    y = mid.to_u64 &+ right.to_u64
    ((scale_factor &* x) ^ (scale_factor &* y)).leading_zeros_count.to_i32!
  end

  # Approximates sqrt(n) as 2^(log2(n) / 2), with the exponent rounded up to
  # compensate for the flooring integer log on average, followed by one
  # iteration of Newton's method.
  protected def self.sqrt_approx(n : Int32) : Int32
    ilog = (n | 1).bit_length - 1
    shift = (ilog + 1) // 2
    ((1 << shift) + (n >> shift)) // 2
  end

  protected def self.stable_sort!(v : Slice(T), comp) forall T
    size = v.size
    return if size < 2

    if size <= STABLE_SMALL_SORT
      insertion_sort!(v.to_unsafe, size, comp)
      return
    end

    # Fully ascending and descending inputs are common enough to deserve
    # finishing in n - 1 comparisons without allocating any scratch space.
    # The detected first run is handed down to `drift_sort!` so it is never
    # scanned twice.
    first_run_len, first_run_reversed = find_natural_run(v, comp)
    if first_run_len == size
      v.reverse! if first_run_reversed
      return
    end

    scratch_len = Math.max(size - size // 2, Math.min(size, STABLE_MAX_FULL_ALLOC_BYTES // Math.max(sizeof(T), 1)))
    scratch = Pointer(T).malloc(scratch_len)

    # For small inputs quicksort is not yet beneficial: one or two
    # small-sorts plus a single merge outperform it, so sort runs eagerly.
    eager_sort = size <= STABLE_SMALL_SORT * 2
    drift_sort!(v, scratch, scratch_len, eager_sort, first_run_len, first_run_reversed, comp)
  end

  # Identical to `drift_sort!` above, but using the comparator block.
  protected def self.drift_sort!(v : Slice(T), scratch : Pointer(T), scratch_len, eager_sort, first_run_len, first_run_reversed, comp) forall T
    size = v.size
    return if size < 2

    scale_factor = merge_tree_scale_factor(size)

    min_good_run_len =
      if size <= MIN_SQRT_RUN_LEN * MIN_SQRT_RUN_LEN
        Math.min(size - size // 2, MIN_SQRT_RUN_LEN)
      else
        sqrt_approx(size)
      end

    runs = uninitialized StaticArray(Tuple(Int32, Bool), 66)
    desired_depths = uninitialized StaticArray(Int32, 66)
    stack_len = 0

    scan_idx = 0
    prev_run_len = 0
    prev_sorted = true # Initial dummy run.

    loop do
      if scan_idx < size
        next_run_len, next_sorted =
          if scan_idx == 0 && first_run_len >= 0
            adopt_run(v, first_run_len, first_run_reversed, min_good_run_len, eager_sort, comp)
          else
            create_run(v[scan_idx, size - scan_idx], min_good_run_len, eager_sort, comp)
          end
        desired_depth = merge_tree_depth(scan_idx - prev_run_len, scan_idx, scan_idx + next_run_len, scale_factor)
      else
        next_run_len, next_sorted = 0, true
        desired_depth = 0
      end

      while stack_len > 1 && desired_depths[stack_len - 1] >= desired_depth
        left_run_len, left_sorted = runs[stack_len - 1]
        merged_len = left_run_len + prev_run_len
        merge_start = scan_idx - merged_len
        prev_sorted = logical_merge!(v[merge_start, merged_len], scratch, scratch_len, left_run_len, left_sorted, prev_sorted, comp)
        prev_run_len = merged_len
        stack_len -= 1
      end

      runs[stack_len] = {prev_run_len, prev_sorted}
      desired_depths[stack_len] = desired_depth
      stack_len += 1

      break if scan_idx >= size

      scan_idx += next_run_len
      prev_run_len = next_run_len
      prev_sorted = next_sorted
    end

    unless prev_sorted
      stable_quicksort!(v, scratch, scratch_len, comp)
    end
  end

  protected def self.create_run(v : Slice(T), min_good_run_len, eager_sort, comp) forall T
    if v.size >= min_good_run_len
      run_len, was_reversed = find_natural_run(v, comp)
      adopt_run(v, run_len, was_reversed, min_good_run_len, eager_sort, comp)
    else
      adopt_run(v, 0, false, min_good_run_len, eager_sort, comp)
    end
  end

  protected def self.adopt_run(v : Slice(T), run_len, was_reversed, min_good_run_len, eager_sort, comp) forall T
    size = v.size
    if run_len >= min_good_run_len
      v[0, run_len].reverse! if was_reversed
      return {run_len, true}
    end

    if eager_sort
      run_len = Math.min(STABLE_SMALL_SORT, size)
      insertion_sort!(v.to_unsafe, run_len, comp)
      {run_len, true}
    else
      {Math.min(min_good_run_len, size), false}
    end
  end

  protected def self.find_natural_run(v : Slice(T), comp) forall T
    size = v.size
    return {size, false} if size < 2

    a = v.to_unsafe
    run_len = 2
    if cmp(a[1], a[0], comp) < 0
      while run_len < size && cmp(a[run_len], a[run_len - 1], comp) < 0
        run_len += 1
      end
      {run_len, true}
    else
      while run_len < size && cmp(a[run_len], a[run_len - 1], comp) >= 0
        run_len += 1
      end
      {run_len, false}
    end
  end

  protected def self.logical_merge!(v : Slice(T), scratch : Pointer(T), scratch_len, mid, left_sorted, right_sorted, comp) forall T
    if v.size > scratch_len || left_sorted || right_sorted
      stable_quicksort!(v[0, mid], scratch, scratch_len, comp) unless left_sorted
      stable_quicksort!(v[mid..], scratch, scratch_len, comp) unless right_sorted
      merge!(v, mid, scratch, comp)
      true
    else
      false
    end
  end

  protected def self.stable_quicksort!(v : Slice(T), scratch : Pointer(T), scratch_len, comp) forall T
    # Limit the number of imbalanced partitions to `2 * floor(log2(len))`.
    limit = 2 * ((v.size | 1).bit_length - 1)
    stable_quicksort!(v, scratch, scratch_len, limit, Pointer(T).null, comp)
  end

  protected def self.stable_quicksort!(v : Slice(T), scratch : Pointer(T), scratch_len, limit, ancestor_pivot : Pointer(T), comp) forall T
    raise "BUG: driftsort quicksort range exceeds the scratch space" if v.size > scratch_len

    loop do
      size = v.size

      if size <= STABLE_SMALL_SORT
        insertion_sort!(v.to_unsafe, size, comp)
        return
      end

      if limit == 0
        drift_sort!(v, scratch, scratch_len, true, -1, false, comp)
        return
      end
      limit -= 1

      pivot = v.unsafe_fetch(choose_stable_pivot(v, comp))

      equal_partition = !ancestor_pivot.null? && cmp(ancestor_pivot.value, pivot, comp) >= 0

      num_lt = 0
      unless equal_partition
        num_lt = stable_partition!(v, scratch, pivot, 0, comp)
        equal_partition = num_lt == 0
      end

      if equal_partition
        num_le = stable_partition!(v, scratch, pivot, 1, comp)
        v = v[num_le..]
        ancestor_pivot = Pointer(T).null
        next
      end

      stable_quicksort!(v[num_lt..], scratch, scratch_len, limit, pointerof(pivot), comp)
      v = v[0, num_lt]
    end
  end

  protected def self.stable_partition!(v : Slice(T), scratch : Pointer(T), pivot : T, bound, comp) forall T
    size = v.size

    scan = v.to_unsafe
    num_left = 0
    scratch_rev = scratch + size

    i = 0
    while i < size
      x = scan[i]
      towards_left = cmp(x, pivot, comp) < bound
      scratch_rev -= 1
      dst = (towards_left ? scratch : scratch_rev) + num_left
      dst.value = x
      num_left += towards_left ? 1 : 0
      i += 1
    end

    scan.copy_from(scratch, num_left)
    num_right = size - num_left
    dst = scan + num_left
    src = scratch + size - 1
    i = 0
    while i < num_right
      dst[i] = (src - i).value
      i += 1
    end

    num_left
  end

  protected def self.choose_stable_pivot(v : Slice(T), comp) forall T
    size = v.size
    base = v.to_unsafe
    len_div_8 = size // 8

    a = base                 # [0, n/8)
    b = base + len_div_8 * 4 # [4n/8, 5n/8)
    c = base + len_div_8 * 7 # [7n/8, n)

    median =
      if size < PSEUDO_MEDIAN_REC_THRESHOLD
        median3(a, b, c, comp)
      else
        median3_rec(a, b, c, len_div_8, comp)
      end
    (median - base).to_i32
  end

  protected def self.median3_rec(a : Pointer(T), b : Pointer(T), c : Pointer(T), n, comp) forall T
    if n * 8 >= PSEUDO_MEDIAN_REC_THRESHOLD
      n8 = n // 8
      a = median3_rec(a, a + n8 * 4, a + n8 * 7, n8, comp)
      b = median3_rec(b, b + n8 * 4, b + n8 * 7, n8, comp)
      c = median3_rec(c, c + n8 * 4, c + n8 * 7, n8, comp)
    end
    median3(a, b, c, comp)
  end

  protected def self.median3(a : Pointer(T), b : Pointer(T), c : Pointer(T), comp) forall T
    x = cmp(a.value, b.value, comp) < 0
    y = cmp(a.value, c.value, comp) < 0
    if x == y
      z = cmp(b.value, c.value, comp) < 0
      z != x ? c : b
    else
      a
    end
  end

  # Merges non-decreasing runs `v[..mid]` and `v[mid..]` using `buf` as
  # temporary storage (it must fit the shorter of the two runs), and stores
  # the result into `v[..]`.
  protected def self.merge!(v, mid, buf, comp)
    size = v.size

    if mid <= size - mid
      # The left run is shorter.
      buf.copy_from(v.to_unsafe, mid)

      left = 0
      right = mid
      out = v.to_unsafe

      while left < mid && right < size
        # Consume the lesser side.
        # If equal, prefer the left run to maintain stability.
        if cmp(v[right], buf[left], comp) < 0
          out.value = v[right]
          out += 1
          right += 1
        else
          out.value = buf[left]
          out += 1
          left += 1
        end
      end

      out.copy_from(buf + left, mid - left)
    else
      # The right run is shorter.
      buf.copy_from((v + mid).to_unsafe, size - mid)

      left = mid
      right = size - mid
      out = v.to_unsafe + size

      while left > 0 && right > 0
        # Consume the greater side.
        # If equal, prefer the right run to maintain stability.
        if cmp(buf[right - 1], v[left - 1], comp) < 0
          left -= 1
          out -= 1
          out.value = v[left]
        else
          right -= 1
          out -= 1
          out.value = buf[right]
        end
      end

      (v + left).copy_from(buf, right)
    end
  end
end
