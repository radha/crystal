module Redis::Commands
  # Returns `"PONG"`, or *message* when given.
  def ping
    typed_call({"PING"}) { |v| Cast.string(v) }
  end

  # :ditto:
  def ping(message : String)
    typed_call({"PING", message}) { |v| Cast.string(v) }
  end

  # Returns *message*.
  def_command echo, "ECHO", message : String, cast: :string

  # Selects logical database *index* for this connection. Hand-written:
  # `select` is a keyword, so it cannot appear as a bare macro argument.
  def select(index : Int)
    typed_call({"SELECT", index}) { |v| Cast.ok(v) }
  end

  # Returns the number of keys in the current database.
  def_command dbsize, "DBSIZE", cast: :int

  # Deletes all keys of the current database.
  def flushdb(*, async : Bool = false)
    typed_call(async ? {"FLUSHDB", "ASYNC"} : {"FLUSHDB"}) { |v| Cast.ok(v) }
  end

  # Deletes all keys of all databases.
  def flushall(*, async : Bool = false)
    typed_call(async ? {"FLUSHALL", "ASYNC"} : {"FLUSHALL"}) { |v| Cast.ok(v) }
  end

  # Returns the server time as `{unix_seconds, microseconds}`.
  def time
    typed_call({"TIME"}) do |v|
      parts = Cast.strings(v)
      Cast.unexpected(v, "TIME pair") unless parts.size == 2
      {parts[0].to_i64? || Cast.unexpected(v, "integer"), parts[1].to_i64? || Cast.unexpected(v, "integer")}
    end
  end

  # Returns `INFO` output (optionally one *section*) parsed into a hash of
  # `key => value`; comment and blank lines are dropped.
  def info(section : String? = nil)
    typed_call(section ? {"INFO", section} : {"INFO"}) do |v|
      hash = {} of String => String
      Cast.string(v).each_line(chomp: true) do |line|
        next if line.empty? || line.starts_with?('#')
        key, _, value = line.partition(':')
        hash[key] = value
      end
      hash
    end
  end
end
