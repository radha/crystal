module Redis
  # RESP2/RESP3 codec over any `IO`. `write_command` encodes a command as a
  # bulk-string array (the form every Redis version accepts); `read` parses
  # one reply into a `Value`.
  module RESP
    # Types accepted as command arguments. Everything but `Bytes` is written
    # with its `to_s` form.
    alias Arg = String | Bytes | Int::Primitive | Float::Primitive | Symbol

    # Redis' own `proto-max-bulk-len` default.
    MAX_BULK_SIZE = 512 * 1024 * 1024
    # Maximum aggregate nesting accepted by `read`.
    MAX_DEPTH = 512

    # Writes *args* as a RESP command into *io* without flushing.
    def self.write_command(io : IO, *args : Arg) : Nil
      write_command(io, args)
    end

    # :ditto:
    def self.write_command(io : IO, args : Enumerable) : Nil
      io << '*' << args.size << "\r\n"
      args.each { |arg| write_bulk(io, arg) }
    end

    private def self.write_bulk(io : IO, arg : String) : Nil
      io << '$' << arg.bytesize << "\r\n" << arg << "\r\n"
    end

    private def self.write_bulk(io : IO, arg : Bytes) : Nil
      io << '$' << arg.size << "\r\n"
      io.write(arg)
      io << "\r\n"
    end

    private def self.write_bulk(io : IO, arg : Symbol) : Nil
      write_bulk(io, arg.to_s)
    end

    private def self.write_bulk(io : IO, arg : Int) : Nil
      io << '$' << decimal_length(arg) << "\r\n" << arg << "\r\n"
    end

    private def self.write_bulk(io : IO, arg : Float) : Nil
      write_bulk(io, arg.to_s)
    end

    # Number of characters `Int#to_s` produces, without allocating.
    private def self.decimal_length(value : Int) : Int32
      length = value < 0 ? 1 : 0
      magnitude = value < 0 ? (0_u64 &- value.to_i64!.to_u64!) : value.to_u64!
      loop do
        length += 1
        magnitude //= 10
        break if magnitude == 0
      end
      length
    end
  end
end
