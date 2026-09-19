module Redis
  # A reply value. RESP3 maps become `Hash`, sets become `Set`, arrays and
  # pushes become `Array`, bulk and simple strings become `String`, error
  # replies nested inside aggregates stay as `CommandError` values.
  alias Value = Nil | Bool | Int64 | Float64 | String | BigNumber | CommandError |
                Array(Value) | Set(Value) | Hash(Value, Value)

  # A RESP3 big number (`(` frame), kept as its decimal text so that
  # `require "redis"` does not depend on GMP. Convert with
  # `BigInt.new(big_number.digits)` after `require "big"`.
  struct BigNumber
    # The decimal text exactly as sent by the server.
    getter digits : String

    def initialize(@digits : String)
    end

    def to_s(io : IO) : Nil
      io << @digits
    end

    def_equals_and_hash @digits
  end
end
