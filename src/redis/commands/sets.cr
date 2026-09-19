module Redis::Commands
  # Adds *members*; returns how many were new.
  def_command sadd, "SADD", key : String, members : RESP::Arg, cast: :int, splat: true
  # Removes *members*; returns how many were removed.
  def_command srem, "SREM", key : String, members : RESP::Arg, cast: :int, splat: true
  # Returns all members.
  def_command smembers, "SMEMBERS", key : String, cast: :strings
  # Whether *member* is in the set.
  def_command sismember, "SISMEMBER", key : String, member : RESP::Arg, cast: :bool
  # Membership of each of *members*.
  def_command smismember, "SMISMEMBER", key : String, members : RESP::Arg, cast: :bools, splat: true
  # Returns the number of members.
  def_command scard, "SCARD", key : String, cast: :int
  # Removes and returns a random member.
  def_command spop, "SPOP", key : String, cast: :string?
  # Removes and returns up to *count* random members.
  def_command spop, "SPOP", key : String, count : Int, cast: :strings
  # Returns a random member.
  def_command srandmember, "SRANDMEMBER", key : String, cast: :string?
  # Returns *count* random members (negative allows repeats).
  def_command srandmember, "SRANDMEMBER", key : String, count : Int, cast: :strings
  # Moves *member* from *source* to *destination*.
  def_command smove, "SMOVE", source : String, destination : String, member : RESP::Arg, cast: :bool
  # Intersection of *keys*.
  def_command sinter, "SINTER", keys : String, cast: :strings, splat: true
  # Union of *keys*.
  def_command sunion, "SUNION", keys : String, cast: :strings, splat: true
  # Difference of the first key against the rest.
  def_command sdiff, "SDIFF", keys : String, cast: :strings, splat: true
  # Stores the intersection of *keys* in *destination*; returns its size.
  def_command sinterstore, "SINTERSTORE", destination : String, keys : String, cast: :int, splat: true
  # Stores the union of *keys* in *destination*.
  def_command sunionstore, "SUNIONSTORE", destination : String, keys : String, cast: :int, splat: true
  # Stores the difference in *destination*.
  def_command sdiffstore, "SDIFFSTORE", destination : String, keys : String, cast: :int, splat: true

  # One `SSCAN` step. Returns `{next_cursor, members}`.
  def sscan(key : String, cursor : String, *, match : String? = nil, count : Int? = nil)
    typed_call(scan_args("SSCAN", key, cursor, match, count)) { |v| Cast.scan_page(v) }
  end
end
