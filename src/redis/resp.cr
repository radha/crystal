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

    # :ditto: *args* is an `Indexable` (for example an `Array`, `Tuple`, or
    # `Deque`) so its size can be read without draining it.
    def self.write_command(io : IO, args : Indexable) : Nil
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
    private def self.decimal_length(value : Int8 | Int16 | Int32 | Int64 | UInt8 | UInt16 | UInt32 | UInt64) : Int32
      length = value < 0 ? 1 : 0
      magnitude = value < 0 ? (0_u64 &- value.to_i64!.to_u64!) : value.to_u64!
      loop do
        length += 1
        magnitude //= 10
        break if magnitude == 0
      end
      length
    end

    # :ditto:
    private def self.decimal_length(value : Int128 | UInt128) : Int32
      length = value < 0 ? 1 : 0
      magnitude = value < 0 ? (0_u128 &- value.to_i128!.to_u128!) : value.to_u128!
      loop do
        length += 1
        magnitude //= 10
        break if magnitude == 0
      end
      length
    end

    # Reads one reply from *io*. Push frames (`>`) are handed to *push* (or
    # dropped) and reading continues with the next frame, so the return
    # value is always a non-push reply. Attribute frames (`|`) are parsed
    # and discarded. An error reply is returned as a `CommandError` value,
    # not raised.
    #
    # Raises `IO::EOFError` if *io* is at EOF before the first byte of a
    # frame, `ProtocolError` on malformed input, on EOF inside a frame, on
    # a bulk string or aggregate count above *max_bulk_size*, or on nesting
    # deeper than *max_depth*.
    def self.read(io : IO, *, max_bulk_size : Int32 = MAX_BULK_SIZE, max_depth : Int32 = MAX_DEPTH,
                  push : (Array(Value) ->)? = nil) : Value
      Parser.new(io, max_bulk_size, max_depth, push).read_reply
    end

    # :nodoc:
    struct Parser
      # Presize hint cap: the count itself is still bounded by max_bulk_size.
      PRESIZE_LIMIT = 4096

      def initialize(@io : IO, @max_bulk_size : Int32, @max_depth : Int32, @push : (Array(Value) ->)?)
      end

      def read_reply : Value
        loop do
          type = @io.read_byte || raise IO::EOFError.new
          begin
            if type === '>'
              array = read_array_body(0) || raise ProtocolError.new("null push frame")
              @push.try &.call(array)
              next
            end
            return read_value(type, 0)
          rescue ex : IO::EOFError
            raise ProtocolError.new("unexpected EOF inside a RESP frame", cause: ex)
          end
        end
      end

      private def read_value(depth : Int32) : Value
        read_value(next_byte, depth)
      end

      private def read_value(type : UInt8, depth : Int32) : Value
        case type.unsafe_chr
        when '+' then read_line
        when '-' then CommandError.new(read_line)
        when ':' then read_int
        when '$' then read_bulk
        when '_' then expect_crlf; nil
        when '#' then read_bool
        when ',' then read_double
        when '(' then BigNumber.new(read_line)
        when '!' then CommandError.new(read_bulk || raise ProtocolError.new("null bulk error"))
        when '=' then read_verbatim
        when '*' then read_array_body(depth)
        when '%' then read_map_body(depth)
        when '~' then read_set_body(depth)
        when '|' then read_map_body(depth); read_value(depth)
        when '>' then raise ProtocolError.new("push frame inside an aggregate")
        else          raise ProtocolError.new("unknown RESP type byte #{type.unsafe_chr.inspect}")
        end
      end

      private def next_byte : UInt8
        @io.read_byte || raise IO::EOFError.new
      end

      private def expect_crlf : Nil
        raise ProtocolError.new("expected CRLF") unless next_byte === '\r' && next_byte === '\n'
      end

      private def read_line : String
        line = @io.gets('\r', chomp: true) || raise IO::EOFError.new
        raise ProtocolError.new("expected LF after CR") unless next_byte === '\n'
        line
      end

      private def read_int : Int64
        byte = next_byte
        negative = false
        case byte.unsafe_chr
        when '-' then negative = true; byte = next_byte
        when '+' then byte = next_byte
        end
        raise ProtocolError.new("expected a digit") unless '0'.ord <= byte <= '9'.ord
        value = 0_i64
        loop do
          value = value * 10 + (byte - '0'.ord)
          byte = next_byte
          break if byte === '\r'
          raise ProtocolError.new("expected a digit") unless '0'.ord <= byte <= '9'.ord
        end
        raise ProtocolError.new("expected LF after CR") unless next_byte === '\n'
        negative ? -value : value
      rescue ex : OverflowError
        raise ProtocolError.new("integer out of range", cause: ex)
      end

      private def read_length : Int32
        length = read_int
        return -1 if length == -1
        raise ProtocolError.new("negative length #{length}") if length < 0
        raise ProtocolError.new("length #{length} exceeds max_bulk_size #{@max_bulk_size}") if length > @max_bulk_size
        length.to_i32
      end

      private def read_bulk : String?
        length = read_length
        return nil if length < 0
        read_bulk_body(length)
      end

      private def read_bulk_body(length : Int32) : String
        io = @io
        string = String.new(length) do |buffer|
          io.read_fully(Slice.new(buffer, length))
          {length, 0}
        end
        expect_crlf
        string
      end

      private def read_verbatim : String
        length = read_length
        raise ProtocolError.new("null verbatim string") if length < 0
        body = read_bulk_body(length)
        if body.bytesize >= 4 && body.byte_at(3) === ':'
          body.byte_slice(4)
        else
          raise ProtocolError.new("verbatim string without format prefix")
        end
      end

      private def read_bool : Bool
        value = case next_byte.unsafe_chr
                when 't' then true
                when 'f' then false
                else          raise ProtocolError.new("expected 't' or 'f'")
                end
        expect_crlf
        value
      end

      private def read_double : Float64
        line = read_line
        case line
        when "inf"  then Float64::INFINITY
        when "-inf" then -Float64::INFINITY
        when "nan"  then Float64::NAN
        else             line.to_f64? || raise ProtocolError.new("invalid double #{line.inspect}")
        end
      end

      private def read_array_body(depth : Int32) : Array(Value)?
        count = read_length
        return nil if count < 0
        depth = enter(depth)
        hint = Math.min(count, PRESIZE_LIMIT)
        array = Array(Value).new(hint)
        count.times { array << read_value(depth) }
        array
      end

      private def read_map_body(depth : Int32) : Hash(Value, Value)
        count = read_length
        raise ProtocolError.new("null map") if count < 0
        depth = enter(depth)
        hint = Math.min(count, PRESIZE_LIMIT)
        hash = Hash(Value, Value).new(initial_capacity: hint)
        count.times do
          key = read_value(depth)
          hash[key] = read_value(depth)
        end
        hash
      end

      private def read_set_body(depth : Int32) : Set(Value)
        count = read_length
        raise ProtocolError.new("null set") if count < 0
        depth = enter(depth)
        hint = Math.min(count, PRESIZE_LIMIT)
        set = Set(Value).new(hint)
        count.times { set << read_value(depth) }
        set
      end

      private def enter(depth : Int32) : Int32
        depth += 1
        raise ProtocolError.new("nesting depth #{depth} exceeds max_depth #{@max_depth}") if depth > @max_depth
        depth
      end
    end
  end
end
