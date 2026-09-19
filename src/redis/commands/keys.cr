module Redis::Commands
  # Deletes *keys*; returns how many existed.
  def_command del, "DEL", keys : String, cast: :int, splat: true
  # Like `del` but reclaims memory asynchronously.
  def_command unlink, "UNLINK", keys : String, cast: :int, splat: true
  # Returns how many of *keys* exist.
  def_command exists, "EXISTS", keys : String, cast: :int, splat: true
  # Returns the type name of *key* (`"string"`, `"list"`, ..., `"none"`).
  def_command type, "TYPE", key : String, cast: :string
  # Renames *key* to *newkey*.
  def_command rename, "RENAME", key : String, newkey : String, cast: :ok
  # Renames *key* only if *newkey* does not exist.
  def_command renamenx, "RENAMENX", key : String, newkey : String, cast: :bool
  # Returns keys matching *pattern*. Prefer `scan_each` on large databases.
  def_command keys, "KEYS", pattern : String, cast: :strings
  # Removes the expiration of *key*.
  def_command persist, "PERSIST", key : String, cast: :bool
  # Remaining time to live in seconds (-1 no expiry, -2 no key).
  def_command ttl, "TTL", key : String, cast: :int
  # Remaining time to live in milliseconds.
  def_command pttl, "PTTL", key : String, cast: :int

  # Sets a timeout on *key*. *ttl* is a `Time::Span` or seconds. A *ttl* that
  # is a `Time::Span` with a sub-second remainder switches to the
  # millisecond form (`PEXPIRE`). Returns `true` if the timeout was set.
  # Flags map to `NX`/`XX`/`GT`/`LT`.
  def expire(key : String, ttl : Time::Span | Int, *, nx = false, xx = false, gt = false, lt = false)
    if sub_second?(ttl)
      expire_command("PEXPIRE", key, ttl_millis(ttl), nx, xx, gt, lt)
    else
      expire_command("EXPIRE", key, ttl_seconds(ttl), nx, xx, gt, lt)
    end
  end

  # Like `expire` with a millisecond *ttl*.
  def pexpire(key : String, ttl : Time::Span | Int, *, nx = false, xx = false, gt = false, lt = false)
    expire_command("PEXPIRE", key, ttl_millis(ttl), nx, xx, gt, lt)
  end

  # Sets the expiration of *key* to a Unix timestamp in seconds.
  def expireat(key : String, timestamp : Int, *, nx = false, xx = false, gt = false, lt = false)
    expire_command("EXPIREAT", key, timestamp, nx, xx, gt, lt)
  end

  # Sets the expiration of *key* to a Unix timestamp in milliseconds.
  def pexpireat(key : String, timestamp : Int, *, nx = false, xx = false, gt = false, lt = false)
    expire_command("PEXPIREAT", key, timestamp, nx, xx, gt, lt)
  end

  private def expire_command(cmd : String, key : String, value : Int, nx, xx, gt, lt)
    args = Array(RESP::Arg).new(4)
    args << cmd << key << value
    args << "NX" if nx
    args << "XX" if xx
    args << "GT" if gt
    args << "LT" if lt
    typed_call(args) { |v| Cast.bool(v) }
  end

  # Converts a `Time::Span` or plain `Int` *ttl* to whole seconds.
  private def ttl_seconds(ttl : Time::Span | Int) : Int64
    ttl.is_a?(Time::Span) ? ttl.total_seconds.to_i64 : ttl.to_i64
  end

  # Converts a `Time::Span` or plain `Int` *ttl* to milliseconds.
  private def ttl_millis(ttl : Time::Span | Int) : Int64
    ttl.is_a?(Time::Span) ? ttl.total_milliseconds.to_i64 : ttl.to_i64
  end

  # `true` only when *ttl* is a `Time::Span` that does not fall on a whole
  # second, meaning it needs the millisecond command variant.
  private def sub_second?(ttl : Time::Span | Int) : Bool
    ttl.is_a?(Time::Span) && ttl.total_milliseconds.to_i64 % 1000 != 0
  end

  # One `SCAN` step. Returns `{next_cursor, keys}`; the cursor `"0"` marks
  # the end of the iteration.
  def scan(cursor : String, *, match : String? = nil, count : Int? = nil, type : String? = nil)
    args = Array(RESP::Arg).new(8)
    args << "SCAN" << cursor
    args << "MATCH" << match if match
    args << "COUNT" << count if count
    args << "TYPE" << type if type
    typed_call(args) { |v| Cast.scan_page(v) }
  end

  # Iterates every key matching *match*, issuing `SCAN` until the cursor
  # returns to `"0"`. Not available on a pipeline.
  def scan_each(*, match : String? = nil, count : Int? = nil, type : String? = nil, & : String ->) : Nil
    cursor = "0"
    loop do
      cursor, keys = scan(cursor, match: match, count: count, type: type)
      keys.each { |key| yield key }
      break if cursor == "0"
    end
  end
end
