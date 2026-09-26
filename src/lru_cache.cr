# An `LRUCache` holds a bounded number of entries and evicts the least
# recently used one when it is full.
#
# Reads with `[]?`, `[]` and `fetch` count as a use and move the entry to
# the front. `peek` and `has_key?` read without refreshing it. Every
# operation runs in O(1). Entries live in slots that removed entries free
# up, so the cache does not allocate per entry.
#
# ```
# require "lru_cache"
#
# cache = LRUCache(String, Int32).new(2)
# cache["a"] = 1
# cache["b"] = 2
# cache["a"]?                         # => 1 ("a" is now the most recently used)
# cache["c"] = 3                      # evicts "b"
# cache["b"]?                         # => nil
# cache.fetch("d") { |key| key.size } # => 1, computed and stored
# cache.hits                          # => 1
# ```
#
# The cache can instead be bounded by a total weight, with a block that
# weighs each entry:
#
# ```
# cache = LRUCache(String, Bytes).new(max_weight: 64 * 1024 * 1024) { |_, value| value.size }
# ```
#
# With a *ttl*, an entry expires that long after it was last written. Expired
# entries are dropped when they are next accessed or by `purge_expired`.
#
# `on_evict` registers a block that runs whenever an entry leaves the cache,
# with the reason (see `EvictionReason`).
#
# `LRUCache` is not safe to share between fibers that may run concurrently.
# Use `SyncLRUCache` for that.
#
# NOTE: To use `LRUCache`, you must explicitly import it with `require "lru_cache"`
class LRUCache(K, V)
  include Enumerable({K, V})

  # Why an entry left the cache, as passed to the `on_evict` block.
  enum EvictionReason
    # Evicted to stay within the capacity or maximum weight.
    Capacity
    # Its time to live ran out.
    Expired
    # A new value was written for its key.
    Replaced
    # Removed by `delete` or `clear`.
    Deleted
  end

  # Marks the end of the recency list and of the free-slot list.
  private NONE = -1

  # :nodoc:
  #
  # One entry: key, value and the hash tag the index files it under.
  struct Slot(K, V)
    getter key : K
    getter value : V
    getter tag : UInt32

    def initialize(@key : K, @value : V, @tag : UInt32)
    end
  end

  # Slots, indexed by slot number.
  @slots = Pointer(Slot(K, V)).null
  # Recency links, `prev` then `next` for each slot, kept apart from the
  # slots so that relinking touches a dense array. `next` also chains the
  # free slots.
  @links = Pointer(Int32).null
  # Allocated only for caches bounded by weight, and only for caches with a
  # time to live.
  @weights = Pointer(Int64).null
  @deadlines = Pointer(Time::Instant).null

  @slot_capacity = 0
  # Slots in use or on the free list; slots at or past this are untouched.
  @slots_used = 0
  @free = NONE

  # Most recently used first.
  @head = NONE
  @tail = NONE

  # The index: an open-addressing table of `tag << 32 | slot + 1` entries
  # (0 for empty), linear probing, at most half full. A key's home bucket
  # is the top bits of its tag, so the table can be probed and rehashed
  # from the tags alone.
  @table : Pointer(UInt64)
  @table_bits = 3
  @mask = 7
  @count = 0

  @capacity : Int32
  @max_weight : Int64
  @weight = 0_i64
  @weigher : Proc(K, V, Int64)?
  @ttl : Time::Span?
  @on_evict : Proc(K, V, EvictionReason, Nil)?

  # Number of reads that found their key.
  getter hits = 0_i64
  # Number of reads that did not find their key (or found it expired).
  getter misses = 0_i64
  # Number of entries evicted for capacity or expiry.
  getter evictions = 0_i64

  # Creates a cache that holds up to *capacity* entries. With *ttl*, entries
  # expire that long after they were last written.
  #
  # ```
  # cache = LRUCache(Int32, String).new(1000, ttl: 5.minutes)
  # ```
  def initialize(capacity : Int, *, ttl : Time::Span? = nil)
    raise ArgumentError.new("Negative capacity: #{capacity}") if capacity < 0
    @capacity = capacity.to_i32
    @max_weight = Int64::MAX
    @weigher = nil
    @table = Pointer(UInt64).malloc(1 << @table_bits)
    self.ttl = ttl
  end

  # Creates a cache whose entries weigh at most *max_weight* in total, as
  # measured by the *weigher* block, which receives each key and value and
  # returns an integer weight. An entry heavier than *max_weight* is evicted
  # as soon as it is written.
  #
  # ```
  # cache = LRUCache(String, String).new(max_weight: 1_000_000) { |key, value| key.bytesize + value.bytesize }
  # ```
  def initialize(*, max_weight : Int, ttl : Time::Span? = nil, &weigher : K, V -> W) forall W
    raise ArgumentError.new("Negative max_weight: #{max_weight}") if max_weight < 0
    @capacity = Int32::MAX
    @max_weight = max_weight.to_i64
    @weigher = ->(key : K, value : V) { weigher.call(key, value).to_i64 }
    @table = Pointer(UInt64).malloc(1 << @table_bits)
    self.ttl = ttl
  end

  # Returns the maximum number of entries.
  getter capacity : Int32

  # Returns the maximum total weight (`Int64::MAX` for a cache bounded by
  # count).
  getter max_weight : Int64

  # Returns the total weight of the entries, or 0 for a cache bounded by
  # count.
  getter weight : Int64

  # Returns the time to live, if any.
  getter ttl : Time::Span?

  # Returns the number of entries, including expired ones that have not
  # been dropped yet.
  def size : Int32
    @count
  end

  # Returns `true` if the cache has no entries.
  def empty? : Bool
    @count == 0
  end

  # Changes the maximum number of entries, evicting the least recently used
  # entries at once if the cache holds more.
  def capacity=(capacity : Int) : Int
    raise ArgumentError.new("Negative capacity: #{capacity}") if capacity < 0
    @capacity = capacity.to_i32
    evict_overflow
    capacity
  end

  # Changes the maximum total weight, evicting the least recently used
  # entries at once if the cache weighs more. Raises `ArgumentError` for a
  # cache created without a weigher.
  def max_weight=(max_weight : Int) : Int
    raise ArgumentError.new("Cache has no weigher") unless @weigher
    raise ArgumentError.new("Negative max_weight: #{max_weight}") if max_weight < 0
    @max_weight = max_weight.to_i64
    evict_overflow
    max_weight
  end

  # Changes the time to live. Entries written before keep their deadline.
  def ttl=(ttl : Time::Span?) : Time::Span?
    raise ArgumentError.new("Non-positive ttl: #{ttl}") if ttl && ttl <= Time::Span.zero
    if ttl && @deadlines.null?
      @deadlines = Pointer(Time::Instant).malloc(@slot_capacity)
      now = Time.instant
      @slots_used.times { |i| @deadlines[i] = now + ttl }
    end
    @ttl = ttl
  end

  # Registers a block that runs after an entry leaves the cache, with its
  # key, value and the reason. Replaces any previous block.
  #
  # ```
  # cache = LRUCache(String, File).new(64)
  # cache.on_evict { |_, file, _| file.close }
  # ```
  def on_evict(&block : K, V, EvictionReason ->) : Nil
    @on_evict = block
  end

  # Returns the value for *key* and marks it as most recently used, or
  # returns `nil` if the cache has no live entry for *key*.
  def []?(key : K) : V?
    if slot = live_slot(key)
      @hits &+= 1
      promote(slot)
      @slots[slot].value
    else
      @misses &+= 1
      nil
    end
  end

  # Returns the value for *key* and marks it as most recently used. Raises
  # `KeyError` if the cache has no live entry for *key*.
  def [](key : K) : V
    if slot = live_slot(key)
      @hits &+= 1
      promote(slot)
      @slots[slot].value
    else
      @misses &+= 1
      raise KeyError.new "Missing LRU cache key: #{key.inspect}"
    end
  end

  # Returns the value for *key*, marking it as most recently used. On a miss
  # it yields *key*, stores the block's value and returns it.
  #
  # ```
  # cache = LRUCache(Int32, Int32).new(100)
  # cache.fetch(7) { |key| key * key }          # => 49, computed
  # cache.fetch(7) { |key| raise "not called" } # => 49
  # ```
  def fetch(key : K, & : K -> V) : V
    if slot = live_slot(key)
      @hits &+= 1
      promote(slot)
      @slots[slot].value
    else
      @misses &+= 1
      value = yield key
      self[key] = value
      value
    end
  end

  # :nodoc:
  #
  # Like `[]?`, but wraps a found value in a tuple so that a stored `nil`
  # differs from a miss.
  def lookup(key : K) : {V}?
    if slot = live_slot(key)
      @hits &+= 1
      promote(slot)
      {@slots[slot].value}
    else
      @misses &+= 1
      nil
    end
  end

  # Returns the value for *key* without marking it as used, or `nil` if the
  # cache has no live entry for *key*. Does not count as a hit or miss.
  def peek(key : K) : V?
    if slot = live_slot(key)
      @slots[slot].value
    end
  end

  # Returns `true` if the cache has a live entry for *key*, without marking
  # it as used.
  def has_key?(key : K) : Bool
    !live_slot(key).nil?
  end

  # Stores *value* for *key* as the most recently used entry, then evicts
  # least recently used entries while the cache is over capacity or weight.
  def []=(key : K, value : V) : V
    if slot = find(key)
      old = @slots[slot].value
      value_ptr(slot).value = value
      reweigh(slot, key, value)
      if ttl = @ttl
        @deadlines[slot] = Time.instant + ttl
      end
      promote(slot)
      notify(key, old, :replaced)
    else
      slot = take_slot
      tag = tag_of(key)
      @slots[slot] = Slot(K, V).new(key, value, tag)
      if @weigher
        @weights[slot] = 0
        reweigh(slot, key, value)
      end
      if ttl = @ttl
        @deadlines[slot] = Time.instant + ttl
      end
      link_front(slot)
      index_insert(tag, slot)
    end
    evict_overflow
    value
  end

  # Removes *key* and returns its value, or `nil` if the cache has no such
  # key. Runs the `on_evict` block with `EvictionReason::Deleted`.
  def delete(key : K) : V?
    if slot = find(key)
      value = @slots[slot].value
      remove_slot(slot, :deleted)
      value
    end
  end

  # Removes every entry, running the `on_evict` block for each with
  # `EvictionReason::Deleted`. Keeps the statistics.
  def clear : self
    while (slot = @tail) != NONE
      remove_slot(slot, :deleted)
    end
    self
  end

  # Drops every expired entry now, and returns how many it dropped.
  def purge_expired : Int32
    return 0 unless @ttl
    now = Time.instant
    count = 0
    slot = @tail
    while slot != NONE
      prev = prev_ptr(slot).value
      if @deadlines[slot] <= now
        @evictions += 1
        remove_slot(slot, :expired)
        count += 1
      end
      slot = prev
    end
    count
  end

  # Resets the hit, miss and eviction counters.
  def reset_stats : Nil
    @hits = @misses = @evictions = 0_i64
  end

  # Returns the fraction of reads that hit, or 0.0 before any read.
  def hit_rate : Float64
    total = @hits + @misses
    total == 0 ? 0.0 : @hits / total
  end

  # Yields each live entry, most recently used first, without marking any
  # as used.
  def each(& : {K, V} ->) : Nil
    now = @ttl ? Time.instant : nil
    slot = @head
    while slot != NONE
      following = next_ptr(slot).value
      unless now && @deadlines[slot] <= now
        yield({@slots[slot].key, @slots[slot].value})
      end
      slot = following
    end
  end

  # Returns the keys, most recently used first.
  def keys : Array(K)
    map &.[0]
  end

  # Returns the values, most recently used first.
  def values : Array(V)
    map &.[1]
  end

  def to_s(io : IO) : Nil
    io << "LRUCache{"
    each_with_index do |(key, value), i|
      io << ", " if i > 0
      key.inspect(io)
      io << " => "
      value.inspect(io)
    end
    io << '}'
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end

  # The slot for *key* if it is present and not expired. An expired entry
  # is dropped.
  @[AlwaysInline]
  private def live_slot(key : K) : Int32?
    slot = find(key)
    return nil unless slot
    if @ttl && @deadlines[slot] <= Time.instant
      @evictions += 1
      remove_slot(slot, :expired)
      return nil
    end
    slot
  end

  # Seeds the integer-key hash so that bucket placement cannot be predicted
  # from the keys.
  private HASH_SEED = Random::Secure.rand(UInt64)

  @[AlwaysInline]
  private def tag_of(key : K) : UInt32
    {% if K < Int::Primitive %}
      # A seeded folded multiply (as in foldhash): one 64x64->128 multiply
      # whose halves are xored, much cheaper than the generic hasher.
      product = (key.to_u64! ^ HASH_SEED).to_u128 &* 0x5851F42D4C957F2D_u128
      (product.unsafe_shr(64).to_u64! ^ product.to_u64!).unsafe_shr(32).to_u32!
    {% else %}
      (key.hash &* 0x9E3779B97F4A7C15_u64).unsafe_shr(32).to_u32!
    {% end %}
  end

  @[AlwaysInline]
  private def home(tag : UInt32) : Int32
    tag.unsafe_shr(32 - @table_bits).to_i32!
  end

  private def find(key : K) : Int32?
    tag = tag_of(key)
    i = home(tag)
    while true
      entry = @table[i]
      return nil if entry == 0
      if entry.unsafe_shr(32).to_u32! == tag
        slot = (entry & 0xFFFF_FFFF).to_i32! - 1
        return slot if @slots[slot].key == key
      end
      i = (i + 1) & @mask
    end
  end

  private def index_insert(tag : UInt32, slot : Int32) : Nil
    grow_table if (@count + 1) * 2 > (1 << @table_bits)
    place(tag.to_u64 << 32 | (slot + 1).to_u64)
    @count += 1
  end

  private def place(entry : UInt64) : Nil
    i = home(entry.unsafe_shr(32).to_u32!)
    while @table[i] != 0
      i = (i + 1) & @mask
    end
    @table[i] = entry
  end

  # Removes the entry for *slot*, shifting later entries of the probe run
  # back so that no tombstone is needed.
  private def index_remove(tag : UInt32, slot : Int32) : Nil
    entry = tag.to_u64 << 32 | (slot + 1).to_u64
    i = home(tag)
    while @table[i] != entry
      i = (i + 1) & @mask
    end
    j = i
    while true
      j = (j + 1) & @mask
      moving = @table[j]
      break if moving == 0
      # Move it into the gap unless that would put it before its home.
      if ((j - home(moving.unsafe_shr(32).to_u32!)) & @mask) >= ((j - i) & @mask)
        @table[i] = moving
        i = j
      end
    end
    @table[i] = 0
    @count -= 1
  end

  private def grow_table : Nil
    old = @table
    old_size = 1 << @table_bits
    @table_bits += 1
    @mask = (1 << @table_bits) - 1
    @table = Pointer(UInt64).malloc(1 << @table_bits)
    old_size.times do |i|
      entry = old[i]
      place(entry) unless entry == 0
    end
  end

  @[AlwaysInline]
  private def value_ptr(slot : Int32) : Pointer(V)
    ((@slots + slot).as(Pointer(UInt8)) + offsetof(Slot(K, V), @value)).as(Pointer(V))
  end

  @[AlwaysInline]
  private def prev_ptr(slot : Int32) : Pointer(Int32)
    @links + 2 * slot
  end

  @[AlwaysInline]
  private def next_ptr(slot : Int32) : Pointer(Int32)
    @links + 2 * slot + 1
  end

  private def reweigh(slot : Int32, key : K, value : V) : Nil
    if weigher = @weigher
      weight = weigher.call(key, value)
      raise ArgumentError.new("Negative weight #{weight} for #{key.inspect}") if weight < 0
      @weight += weight - @weights[slot]
      @weights[slot] = weight
    end
  end

  private def evict_overflow : Nil
    while (@count > @capacity || @weight > @max_weight) && (slot = @tail) != NONE
      @evictions += 1
      remove_slot(slot, :capacity)
    end
  end

  # Unlinks *slot*, frees it and runs the `on_evict` block.
  private def remove_slot(slot : Int32, reason : EvictionReason) : Nil
    entry = @slots[slot]
    unlink(slot)
    index_remove(entry.tag, slot)
    @weight -= @weights[slot] if @weigher
    (@slots + slot).clear
    next_ptr(slot).value = @free
    @free = slot
    notify(entry.key, entry.value, reason)
  end

  private def notify(key : K, value : V, reason : EvictionReason) : Nil
    @on_evict.try &.call(key, value, reason)
  end

  private def take_slot : Int32
    if (slot = @free) != NONE
      @free = next_ptr(slot).value
      return slot
    end
    grow if @slots_used == @slot_capacity
    slot = @slots_used
    @slots_used += 1
    slot
  end

  private def grow : Nil
    new_capacity = Math.max(8, @slot_capacity * 2)
    @slots = @slots.realloc(new_capacity)
    @links = @links.realloc(2 * new_capacity)
    @weights = @weights.realloc(new_capacity) if @weigher
    @deadlines = @deadlines.realloc(new_capacity) unless @deadlines.null?
    @slot_capacity = new_capacity
  end

  @[AlwaysInline]
  private def promote(slot : Int32) : Nil
    return if slot == @head
    unlink(slot)
    link_front(slot)
  end

  @[AlwaysInline]
  private def link_front(slot : Int32) : Nil
    prev_ptr(slot).value = NONE
    next_ptr(slot).value = @head
    if @head != NONE
      prev_ptr(@head).value = slot
    else
      @tail = slot
    end
    @head = slot
  end

  @[AlwaysInline]
  private def unlink(slot : Int32) : Nil
    prev = prev_ptr(slot).value
    following = next_ptr(slot).value
    if prev != NONE
      next_ptr(prev).value = following
    else
      @head = following
    end
    if following != NONE
      prev_ptr(following).value = prev
    else
      @tail = prev
    end
  end

  # :nodoc:
  #
  # Checks the list, index, free list and weight against each other. Used
  # by the specs.
  def check_invariants : Nil
    seen = 0
    weight = 0_i64
    slot = @head
    prev = NONE
    while slot != NONE
      raise "broken prev link at #{slot}" unless prev_ptr(slot).value == prev
      raise "index disagrees at #{slot}" unless find(@slots[slot].key) == slot
      raise "stale tag at #{slot}" unless @slots[slot].tag == tag_of(@slots[slot].key)
      weight += @weights[slot] if @weigher
      seen += 1
      prev = slot
      slot = next_ptr(slot).value
    end
    raise "tail is #{@tail}, expected #{prev}" unless @tail == prev
    raise "list has #{seen}, index #{@count}" unless seen == @count
    entries = (0...(1 << @table_bits)).count { |i| @table[i] != 0 }
    raise "table has #{entries} entries, count #{@count}" unless entries == @count
    raise "table over half full" if @count * 2 > (1 << @table_bits)
    raise "weight #{@weight}, expected #{weight}" unless weight == @weight
    free = 0
    slot = @free
    while slot != NONE
      free += 1
      slot = next_ptr(slot).value
    end
    raise "#{seen} live + #{free} free != #{@slots_used} slots" unless seen + free == @slots_used
    raise "over capacity" if seen > @capacity || @weight > @max_weight
  end
end

# A fiber-safe `LRUCache`: each operation holds a `Mutex`.
#
# `fetch` computes a missing value outside the lock, so a slow computation
# does not block other keys, and only once per key: fibers that miss the
# same key while it is being computed wait for that result (or its
# exception) instead of computing it again.
#
# ```
# require "lru_cache"
#
# cache = SyncLRUCache(String, String).new(10_000, ttl: 1.minute)
# spawn { cache.fetch("user:1") { |key| load_user(key) } }
# ```
#
# NOTE: To use `SyncLRUCache`, you must explicitly import it with `require "lru_cache"`
class SyncLRUCache(K, V)
  include Enumerable({K, V})

  # A computation in progress for one key, which other fibers can wait on.
  # Every method runs with the lock held, except `wait`. The channel is
  # created only once a second fiber waits, so an uncontended miss costs
  # no more than this object.
  private class Flight(V)
    @channel : Channel(Nil)?
    @value : V?
    @error : Exception?

    # Registers a waiter and returns the channel to wait on.
    def waiter : Channel(Nil)
      @channel ||= Channel(Nil).new
    end

    def resolve(value : V) : Nil
      @value = value
      @channel.try &.close
    end

    def reject(error : Exception) : Nil
      @error = error
      @channel.try &.close
    end

    # Waits on *channel* (outside the lock) and returns the outcome.
    def wait(channel : Channel(Nil)) : V
      channel.receive?
      if error = @error
        raise error
      end
      @value.as(V)
    end
  end

  @mutex = Mutex.new
  @cache : LRUCache(K, V)
  @flights = Hash(K, Flight(V)).new

  # Creates a cache that holds up to *capacity* entries. See
  # `LRUCache.new(capacity, ttl)`.
  def initialize(capacity : Int, *, ttl : Time::Span? = nil)
    @cache = LRUCache(K, V).new(capacity, ttl: ttl)
  end

  # Creates a cache bounded by total weight. See
  # `LRUCache.new(max_weight, ttl, &weigher)`.
  def initialize(*, max_weight : Int, ttl : Time::Span? = nil, &weigher : K, V -> W) forall W
    @cache = LRUCache(K, V).new(max_weight: max_weight, ttl: ttl) { |key, value| weigher.call(key, value) }
  end

  # See `LRUCache#[]?`.
  def []?(key : K) : V?
    @mutex.synchronize { @cache[key]? }
  end

  # See `LRUCache#[]`.
  def [](key : K) : V
    @mutex.synchronize { @cache[key] }
  end

  # See `LRUCache#[]=`.
  def []=(key : K, value : V) : V
    @mutex.synchronize { @cache[key] = value }
  end

  # See `LRUCache#peek`.
  def peek(key : K) : V?
    @mutex.synchronize { @cache.peek(key) }
  end

  # See `LRUCache#has_key?`.
  def has_key?(key : K) : Bool
    @mutex.synchronize { @cache.has_key?(key) }
  end

  # See `LRUCache#delete`.
  def delete(key : K) : V?
    @mutex.synchronize { @cache.delete(key) }
  end

  # See `LRUCache#clear`.
  def clear : self
    @mutex.synchronize { @cache.clear }
    self
  end

  # See `LRUCache#purge_expired`.
  def purge_expired : Int32
    @mutex.synchronize { @cache.purge_expired }
  end

  # Returns the value for *key*, marking it as most recently used. On a miss
  # it yields *key* outside the lock and stores the block's value. Fibers
  # that miss the same key meanwhile wait for this result; if the block
  # raises, they raise the same exception and nothing is stored.
  def fetch(key : K, & : K -> V) : V
    flight = nil
    channel = nil
    @mutex.synchronize do
      if found = @cache.lookup(key)
        return found[0]
      end
      # A flight in the table is still pending: the owner resolves it and
      # removes it under this lock.
      if flight = @flights[key]?
        channel = flight.waiter
      else
        flight = @flights[key] = Flight(V).new
      end
    end
    flight = flight.not_nil!
    return flight.wait(channel) if channel

    begin
      value = yield key
    rescue ex
      @mutex.synchronize do
        @flights.delete(key)
        flight.reject(ex)
      end
      raise ex
    end
    @mutex.synchronize do
      @cache[key] = value
      @flights.delete(key)
      flight.resolve(value)
    end
    value
  end

  # See `LRUCache#on_evict`. The block runs while the lock is held, so it
  # must not call back into this cache.
  def on_evict(&block : K, V, LRUCache::EvictionReason ->) : Nil
    @mutex.synchronize { @cache.on_evict { |key, value, reason| block.call(key, value, reason) } }
  end

  # Yields a snapshot of the live entries, most recently used first. The
  # lock is not held while yielding.
  def each(& : {K, V} ->) : Nil
    entries = @mutex.synchronize { @cache.to_a }
    entries.each { |entry| yield entry }
  end

  {% for name in %w(size empty? capacity max_weight weight ttl hits misses evictions hit_rate) %}
    # See `LRUCache#{{name.id}}`.
    def {{name.id}}
      @mutex.synchronize { @cache.{{name.id}} }
    end
  {% end %}

  # See `LRUCache#capacity=`.
  def capacity=(capacity : Int) : Int
    @mutex.synchronize { @cache.capacity = capacity }
  end

  # See `LRUCache#max_weight=`.
  def max_weight=(max_weight : Int) : Int
    @mutex.synchronize { @cache.max_weight = max_weight }
  end

  # See `LRUCache#reset_stats`.
  def reset_stats : Nil
    @mutex.synchronize { @cache.reset_stats }
  end
end
