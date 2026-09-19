module Redis::Commands
  # Runs a Lua *script* with *keys* and *args*. Returns the raw `Value`.
  def eval(script : String, *, keys : Array(String) = [] of String, args : Array(RESP::Arg) = [] of RESP::Arg)
    typed_call(script_args("EVAL", script, keys, args)) { |v| Cast.value(v) }
  end

  # Runs a cached script by its SHA1.
  def evalsha(sha : String, *, keys : Array(String) = [] of String, args : Array(RESP::Arg) = [] of RESP::Arg)
    typed_call(script_args("EVALSHA", sha, keys, args)) { |v| Cast.value(v) }
  end

  private def script_args(cmd : String, body : String, keys : Array(String), args : Array(RESP::Arg)) : Array(RESP::Arg)
    all = Array(RESP::Arg).new(3 + keys.size + args.size)
    all << cmd << body << keys.size
    keys.each { |k| all << k }
    args.each { |a| all << a }
    all
  end

  # Loads *script* into the script cache; returns its SHA1.
  def script_load(script : String)
    typed_call({"SCRIPT", "LOAD", script}) { |v| Cast.string(v) }
  end

  # Whether each of *shas* is in the script cache.
  def script_exists(*shas : String)
    args = Array(RESP::Arg).new(2 + shas.size)
    args << "SCRIPT" << "EXISTS"
    shas.each { |s| args << s }
    typed_call(args) { |v| Cast.bools(v) }
  end

  # Empties the script cache.
  def script_flush
    typed_call({"SCRIPT", "FLUSH"}) { |v| Cast.ok(v) }
  end
end
