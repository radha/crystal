module Redis::Commands
  # Adds *member* with *score*; returns how many members were added.
  def zadd(key : String, score : Float | Int, member : RESP::Arg)
    typed_call({"ZADD", key, score, member}) { |v| Cast.int(v) }
  end

  # Adds several `{member, score}` pairs. Flags: `nx` only add, `xx` only
  # update, `gt`/`lt` only update when the new score is greater/less, `ch`
  # count changed members instead of added ones.
  def zadd(key : String, members : Indexable({String, Float64}), *, nx = false, xx = false,
           gt = false, lt = false, ch = false)
    args = zadd_args(key, members.size, nx, xx, gt, lt, ch, incr: false)
    members.each { |(member, score)| args << score << member }
    typed_call(args) { |v| Cast.int(v) }
  end

  # `ZADD ... INCR`: increments *member* by *increment* and returns the new
  # score, or `nil` when an `nx`/`xx`/`gt`/`lt` condition prevented it.
  def zadd_incr(key : String, increment : Float | Int, member : RESP::Arg, *, nx = false, xx = false,
                gt = false, lt = false)
    args = zadd_args(key, 1, nx, xx, gt, lt, false, incr: true)
    args << increment << member
    typed_call(args) { |v| Cast.float?(v) }
  end

  private def zadd_args(key, count, nx, xx, gt, lt, ch, *, incr) : Array(RESP::Arg)
    raise ArgumentError.new("nx and xx are mutually exclusive") if nx && xx
    raise ArgumentError.new("gt and lt are mutually exclusive") if gt && lt
    raise ArgumentError.new("nx cannot be combined with gt or lt") if nx && (gt || lt)
    args = Array(RESP::Arg).new(7 + count * 2)
    args << "ZADD" << key
    args << "NX" if nx
    args << "XX" if xx
    args << "GT" if gt
    args << "LT" if lt
    args << "CH" if ch
    args << "INCR" if incr
    args
  end

  # Removes *members*; returns how many were removed.
  def_command zrem, "ZREM", key : String, members : RESP::Arg, cast: :int, splat: true
  # Returns the score of *member*, or `nil`.
  def_command zscore, "ZSCORE", key : String, member : RESP::Arg, cast: :float?
  # Returns the scores of *members*, `nil` for missing ones.
  def_command zmscore, "ZMSCORE", key : String, members : RESP::Arg, cast: :floats?, splat: true
  # Returns the number of members.
  def_command zcard, "ZCARD", key : String, cast: :int
  # Counts members with scores between *min* and *max* (Redis range syntax, e.g. `"(1"`, `"+inf"`).
  def_command zcount, "ZCOUNT", key : String, min : RESP::Arg, max : RESP::Arg, cast: :int
  # Increments the score of *member*; returns the new score.
  def_command zincrby, "ZINCRBY", key : String, increment : Float | Int, member : RESP::Arg, cast: :float

  # Rank of *member* ascending, or `nil`.
  def zrank(key : String, member : RESP::Arg)
    typed_call({"ZRANK", key, member}) { |v| v.nil? ? nil : Cast.int(v) }
  end

  # Rank of *member* descending, or `nil`.
  def zrevrank(key : String, member : RESP::Arg)
    typed_call({"ZREVRANK", key, member}) { |v| v.nil? ? nil : Cast.int(v) }
  end

  # Members between *start* and *stop*: by rank (default), by score
  # (`by_score: true`, Redis range syntax) or lexicographically
  # (`by_lex: true`). `rev: true` reverses, `limit: {offset, count}` pages.
  def zrange(key : String, start : RESP::Arg, stop : RESP::Arg, *, by_score = false, by_lex = false,
             rev = false, limit : {Int32, Int32}? = nil)
    typed_call(zrange_args(key, start, stop, by_score, by_lex, rev, limit, with_scores: false)) { |v| Cast.strings(v) }
  end

  # Like `zrange`, returning `{member, score}` pairs.
  def zrange_with_scores(key : String, start : RESP::Arg, stop : RESP::Arg, *, by_score = false, by_lex = false,
                         rev = false, limit : {Int32, Int32}? = nil)
    typed_call(zrange_args(key, start, stop, by_score, by_lex, rev, limit, with_scores: true)) { |v| Cast.scored_pairs(v) }
  end

  private def zrange_args(key, start, stop, by_score, by_lex, rev, limit, *, with_scores) : Array(RESP::Arg)
    raise ArgumentError.new("by_score and by_lex are mutually exclusive") if by_score && by_lex
    raise ArgumentError.new("with_scores cannot be combined with by_lex") if with_scores && by_lex
    args = Array(RESP::Arg).new(10)
    args << "ZRANGE" << key << start << stop
    args << "BYSCORE" if by_score
    args << "BYLEX" if by_lex
    args << "REV" if rev
    if limit
      args << "LIMIT" << limit[0] << limit[1]
    end
    args << "WITHSCORES" if with_scores
    args
  end

  # Removes and returns the lowest-scored members (one, or *count*).
  def zpopmin(key : String, count : Int? = nil)
    typed_call(count ? {"ZPOPMIN", key, count} : {"ZPOPMIN", key}) { |v| Cast.scored_pairs(v) }
  end

  # Removes and returns the highest-scored members (one, or *count*).
  def zpopmax(key : String, count : Int? = nil)
    typed_call(count ? {"ZPOPMAX", key, count} : {"ZPOPMAX", key}) { |v| Cast.scored_pairs(v) }
  end

  # One `ZSCAN` step. Returns `{next_cursor, pairs}`.
  def zscan(key : String, cursor : String, *, match : String? = nil, count : Int? = nil)
    typed_call(scan_args("ZSCAN", key, cursor, match, count)) do |v|
      page = Cast.elements(v, "scan page")
      Cast.unexpected(v, "scan page") unless page.size == 2
      {Cast.string(page[0]), Cast.scored_pairs(page[1])}
    end
  end
end
