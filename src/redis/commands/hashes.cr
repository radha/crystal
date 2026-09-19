module Redis::Commands
  # Returns the value of *field* in hash *key*.
  def_command hget, "HGET", key : String, field : String, cast: :string?
  # Sets *field* to *value*; returns the number of fields added.
  def_command hset, "HSET", key : String, field : String, value : RESP::Arg, cast: :int
  # Sets *field* only if it does not exist.
  def_command hsetnx, "HSETNX", key : String, field : String, value : RESP::Arg, cast: :bool
  # Returns the values of *fields*, `nil` for missing ones.
  def_command hmget, "HMGET", key : String, fields : String, cast: :strings?, splat: true
  # Returns all fields and values of hash *key*.
  def_command hgetall, "HGETALL", key : String, cast: :string_hash
  # Deletes *fields*; returns how many were removed.
  def_command hdel, "HDEL", key : String, fields : String, cast: :int, splat: true
  # Whether *field* exists in hash *key*.
  def_command hexists, "HEXISTS", key : String, field : String, cast: :bool
  # Returns the field names of hash *key*.
  def_command hkeys, "HKEYS", key : String, cast: :strings
  # Returns the values of hash *key*.
  def_command hvals, "HVALS", key : String, cast: :strings
  # Returns the number of fields in hash *key*.
  def_command hlen, "HLEN", key : String, cast: :int
  # Increments *field* by *increment*.
  def_command hincrby, "HINCRBY", key : String, field : String, increment : Int, cast: :int
  # Increments *field* by a float *increment*.
  def_command hincrbyfloat, "HINCRBYFLOAT", key : String, field : String, increment : Float, cast: :float

  # Sets several fields at once; returns the number of fields added.
  def hset(key : String, pairs : Hash(String, RESP::Arg) | Hash(String, String))
    args = Array(RESP::Arg).new(2 + pairs.size * 2)
    args << "HSET" << key
    pairs.each { |f, v| args << f << v }
    typed_call(args) { |v| Cast.int(v) }
  end

  # One `HSCAN` step. Returns `{next_cursor, fields}`.
  def hscan(key : String, cursor : String, *, match : String? = nil, count : Int? = nil)
    typed_call(scan_args("HSCAN", key, cursor, match, count)) do |v|
      page = Cast.elements(v, "scan page")
      Cast.unexpected(v, "scan page") unless page.size == 2
      {Cast.string(page[0]), Cast.string_hash(page[1])}
    end
  end
end
