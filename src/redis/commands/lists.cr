module Redis::Commands
  # Prepends *values*; returns the new length.
  def_command lpush, "LPUSH", key : String, values : RESP::Arg, cast: :int, splat: true
  # Appends *values*; returns the new length.
  def_command rpush, "RPUSH", key : String, values : RESP::Arg, cast: :int, splat: true
  # Prepends only if the list exists.
  def_command lpushx, "LPUSHX", key : String, values : RESP::Arg, cast: :int, splat: true
  # Appends only if the list exists.
  def_command rpushx, "RPUSHX", key : String, values : RESP::Arg, cast: :int, splat: true
  # Removes and returns the first element.
  def_command lpop, "LPOP", key : String, cast: :string?
  # Removes and returns the last element.
  def_command rpop, "RPOP", key : String, cast: :string?
  # Returns the length of the list.
  def_command llen, "LLEN", key : String, cast: :int
  # Returns elements from *start* to *stop* (inclusive, negative from end).
  def_command lrange, "LRANGE", key : String, start : Int, stop : Int, cast: :strings
  # Returns the element at *index*.
  def_command lindex, "LINDEX", key : String, index : Int, cast: :string?
  # Sets the element at *index*.
  def_command lset, "LSET", key : String, index : Int, value : RESP::Arg, cast: :ok
  # Removes up to *count* occurrences of *value* (0 = all); returns how many.
  def_command lrem, "LREM", key : String, count : Int, value : RESP::Arg, cast: :int
  # Trims the list to the range *start*..*stop*.
  def_command ltrim, "LTRIM", key : String, start : Int, stop : Int, cast: :ok

  # Removes and returns up to *count* first elements (empty array when the key is missing).
  def lpop(key : String, count : Int)
    typed_call({"LPOP", key, count}) { |v| v.nil? ? [] of String : Cast.strings(v) }
  end

  # Removes and returns up to *count* last elements.
  def rpop(key : String, count : Int)
    typed_call({"RPOP", key, count}) { |v| v.nil? ? [] of String : Cast.strings(v) }
  end

  # Inserts *value* before or after *pivot*; returns the new length, -1 if
  # *pivot* was not found.
  def linsert(key : String, where : Symbol, pivot : RESP::Arg, value : RESP::Arg)
    typed_call({"LINSERT", key, where_arg(where), pivot, value}) { |v| Cast.int(v) }
  end

  # Atomically pops from *source* (`:left`/`:right`) and pushes to
  # *destination* (`:left`/`:right`); returns the moved element.
  def lmove(source : String, destination : String, from : Symbol, to : Symbol)
    typed_call({"LMOVE", source, destination, side_arg(from), side_arg(to)}) { |v| Cast.string?(v) }
  end

  private def where_arg(where : Symbol) : String
    case where
    when :before then "BEFORE"
    when :after  then "AFTER"
    else              raise ArgumentError.new("expected :before or :after, got #{where.inspect}")
    end
  end

  private def side_arg(side : Symbol) : String
    case side
    when :left  then "LEFT"
    when :right then "RIGHT"
    else             raise ArgumentError.new("expected :left or :right, got #{side.inspect}")
    end
  end
end
