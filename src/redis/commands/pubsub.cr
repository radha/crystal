module Redis::Commands
  # Posts *message* to *channel* and returns the number of clients that
  # received it. To receive, see `Redis::Subscriber`.
  def_command publish, "PUBLISH", channel : String, message : String, cast: :int
end
