module Redis::Commands
  # Returns the string value of *key*, or `nil` if it does not exist.
  def_command get, "GET", key : String, cast: :string?

  # Sets *key* to *value*. Options: `ex`/`px` relative TTL (`Time::Span` or
  # seconds/milliseconds), `exat`/`pxat` absolute Unix timestamps, `nx` only
  # if absent, `xx` only if present, `keepttl`, and `get` to return the old
  # value. An `ex` given as a `Time::Span` with a sub-second remainder is
  # sent as `PX` instead. Returns `"OK"`, `nil` when an `nx`/`xx` condition
  # fails, or the previous value with `get: true`.
  def set(key : String, value : RESP::Arg, *, ex : Time::Span | Int | Nil = nil, px : Time::Span | Int | Nil = nil,
          exat : Int? = nil, pxat : Int? = nil, nx : Bool = false, xx : Bool = false,
          keepttl : Bool = false, get : Bool = false)
    raise ArgumentError.new("nx and xx are mutually exclusive") if nx && xx
    ttl_options = {ex, px, exat, pxat}.count { |o| !o.nil? } + (keepttl ? 1 : 0)
    raise ArgumentError.new("ex, px, exat, pxat and keepttl are mutually exclusive") if ttl_options > 1
    args = Array(RESP::Arg).new(8)
    args << "SET" << key << value
    if ex
      if sub_second?(ex)
        args << "PX" << ttl_millis(ex)
      else
        args << "EX" << ttl_seconds(ex)
      end
    elsif px
      args << "PX" << ttl_millis(px)
    elsif exat
      args << "EXAT" << exat
    elsif pxat
      args << "PXAT" << pxat
    end
    args << "NX" if nx
    args << "XX" if xx
    args << "KEEPTTL" if keepttl
    args << "GET" if get
    typed_call(args) { |v| Cast.string?(v) }
  end

  # Sets *key* only if it does not exist.
  def_command setnx, "SETNX", key : String, value : RESP::Arg, cast: :bool

  # Sets *key* with a TTL in seconds. A *ttl* that is a `Time::Span` with a
  # sub-second remainder switches to the millisecond form (`PSETEX`).
  def setex(key : String, ttl : Time::Span | Int, value : RESP::Arg)
    if sub_second?(ttl)
      typed_call({"PSETEX", key, ttl_millis(ttl), value}) { |v| Cast.ok(v) }
    else
      typed_call({"SETEX", key, ttl_seconds(ttl), value}) { |v| Cast.ok(v) }
    end
  end

  # Sets *key* with a TTL in milliseconds.
  def psetex(key : String, ttl : Time::Span | Int, value : RESP::Arg)
    typed_call({"PSETEX", key, ttl_millis(ttl), value}) { |v| Cast.ok(v) }
  end

  # Sets *key* and returns its previous value.
  def_command getset, "GETSET", key : String, value : RESP::Arg, cast: :string?
  # Returns and deletes *key*.
  def_command getdel, "GETDEL", key : String, cast: :string?
  # Returns the values of *keys*, `nil` for missing ones.
  def_command mget, "MGET", keys : String, cast: :strings?, splat: true
  # Increments *key* by one.
  def_command incr, "INCR", key : String, cast: :int
  # Increments *key* by *increment*.
  def_command incrby, "INCRBY", key : String, increment : Int, cast: :int
  # Increments *key* by a float *increment*.
  def_command incrbyfloat, "INCRBYFLOAT", key : String, increment : Float, cast: :float
  # Decrements *key* by one.
  def_command decr, "DECR", key : String, cast: :int
  # Decrements *key* by *decrement*.
  def_command decrby, "DECRBY", key : String, decrement : Int, cast: :int
  # Appends *value*; returns the new length.
  def_command append, "APPEND", key : String, value : RESP::Arg, cast: :int
  # Returns the byte length of *key*'s value.
  def_command strlen, "STRLEN", key : String, cast: :int
  # Returns the substring from *start* to *stop* (inclusive, negative from end).
  def_command getrange, "GETRANGE", key : String, start : Int, stop : Int, cast: :string
  # Overwrites from *offset*; returns the new length.
  def_command setrange, "SETRANGE", key : String, offset : Int, value : RESP::Arg, cast: :int

  # Sets several keys at once.
  def mset(pairs : Hash(String, RESP::Arg) | Hash(String, String))
    typed_call(kv_args("MSET", pairs)) { |v| Cast.ok(v) }
  end

  # Sets several keys only if none exists.
  def msetnx(pairs : Hash(String, RESP::Arg) | Hash(String, String))
    typed_call(kv_args("MSETNX", pairs)) { |v| Cast.bool(v) }
  end

  private def kv_args(cmd : String, pairs : Hash) : Array(RESP::Arg)
    args = Array(RESP::Arg).new(1 + pairs.size * 2)
    args << cmd
    pairs.each { |k, v| args << k << v }
    args
  end
end
