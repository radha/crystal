require "./connection"

module Postgres
  class Connection
    # Messages of a `COPY ... FROM STDIN` are sent in chunks of this size.
    COPY_CHUNK = 64 * 1024

    # Runs *sql*, a `COPY ... FROM STDIN` statement, and yields an `IO`
    # that streams whatever the block writes to the server (in the format
    # the statement names: text, CSV or binary). Returns the number of
    # rows copied. If the block raises, the copy is aborted (`CopyFail`),
    # nothing is inserted and the exception propagates.
    #
    # ```
    # conn.copy_from("copy items (id, name) from stdin (format csv)") do |io|
    #   io << "1,apple\n" << "2,pear\n"
    # end # => 2
    # ```
    def copy_from(sql : String, & : IO ->) : Int64
      enter
      begin
        start_copy(sql, 'G')
        writer = CopyWriter.new(self)
        begin
          yield writer
          writer.flush
        rescue ex
          @out.clear
          write_message('f') { |io| io << (ex.message || ex.class.name) << '\0' }
          flush
          finish_copy rescue nil
          raise ex
        end
        write_message('c') { }
        flush
        finish_copy
      ensure
        leave
      end
    end

    # Copies all of *source* into the server with *sql*, a
    # `COPY ... FROM STDIN` statement. Returns the number of rows copied.
    def copy_from(sql : String, source : IO) : Int64
      copy_from(sql) { |io| IO.copy(source, io) }
    end

    # Runs *sql*, a `COPY ... TO STDOUT` statement, and yields an `IO` that
    # reads the data as it arrives (nothing is buffered beyond one
    # message). Returns the number of rows copied. Whatever the block
    # leaves unread is read and discarded afterwards.
    #
    # ```
    # conn.copy_to("copy items to stdout (format csv)") do |io|
    #   io.each_line { |line| puts line }
    # end
    # ```
    def copy_to(sql : String, & : IO ->) : Int64
      enter
      begin
        start_copy(sql, 'H')
        reader = CopyReader.new(self)
        begin
          yield reader
        ensure
          reader.skip_to_end unless @closed
        end
        # A failure ended the stream and the block swallowed it: the
        # session is past `ReadyForQuery` already (or closed).
        if failure = reader.failure
          raise failure
        end
        finish_copy
      ensure
        leave
      end
    end

    # Copies the output of *sql*, a `COPY ... TO STDOUT` statement, into
    # *destination*. Returns the number of rows copied.
    def copy_to(sql : String, destination : IO) : Int64
      copy_to(sql) { |io| IO.copy(io, destination) }
    end

    # Bulk-inserts rows into *table* with a binary `COPY`. *table* is SQL
    # (it may be schema-qualified and is not quoted); *columns* are quoted
    # as identifiers. The column types are looked up once (a cached
    # zero-row `select`), and each value is encoded for its column's type
    # as a query parameter would be, except that binary COPY cannot fall
    # back to text: a value without a binary encoding for its column (a
    # `String` for an `inet` column, say) raises `EncodeError`, which
    # aborts the whole copy. Returns the number of rows copied.
    #
    # ```
    # conn.copy_rows("items", {"id", "name"}) do |copy|
    #   copy.row(1, "apple")
    #   copy.row(2, nil)
    # end # => 2
    # ```
    def copy_rows(table : String, columns : Indexable(String), & : CopyRows ->) : Int64
      raise ArgumentError.new("copy_rows needs at least one column") if columns.empty?
      list = columns.join(", ") { |c| Connection.quote_identifier(c) }
      oids = with_statement("select #{list} from #{table} limit 0") { |s| s.columns.map(&.type_oid) }
      copy_from("copy #{table} (#{list}) from stdin (format binary)") do |io|
        io.write(COPY_SIGNATURE)
        io.write_bytes(0_i32, IO::ByteFormat::BigEndian) # flags
        io.write_bytes(0_i32, IO::ByteFormat::BigEndian) # header extension
        yield CopyRows.new(io, columns, oids)
        io.write_bytes(-1_i16, IO::ByteFormat::BigEndian)
      end
    end

    # :nodoc:
    COPY_SIGNATURE = Bytes['P'.ord, 'G'.ord, 'C'.ord, 'O'.ord, 'P'.ord, 'Y'.ord, '\n'.ord, 0xFF, '\r'.ord, '\n'.ord, 0]

    # :nodoc:
    def self.quote_identifier(name : String) : String
      %("#{name.gsub('"', %(""))}")
    end

    # Prepares (or finds) *sql* and yields the statement, as a query would.
    private def with_statement(sql : String, & : PreparedStatement -> T) : T forall T
      enter
      begin
        yield prepare(sql)
      ensure
        leave
      end
    end

    # Sends *sql* and reads up to the copy response *expected* (`G` in, `H`
    # out). An error (the statement failed, or is no COPY of that
    # direction) is raised after `ReadyForQuery`.
    private def start_copy(sql : String, expected : Char) : Nil
      flush_closes
      Messages::Query.new(query: sql).write(@out)
      flush
      error = nil
      loop do
        type, body = read_message
        case type
        when expected
          return
        when 'G', 'H'
          # The other direction: abort it so the session stays usable.
          if type == 'G'
            write_message('f') { |io| io << "wrong COPY direction\0" }
            flush
          end
          error ||= Error.new("#{sql.inspect} is not a COPY #{expected == 'G' ? "FROM STDIN" : "TO STDOUT"}")
        when 'd', 'c', 'C', 'T', 'D', 'I', '3'
        when 'E' then error ||= parse { query_error(body) }
        when 'Z'
          @transaction_status = ready_status(body)
          raise error || Error.new("#{sql.inspect} did not start a COPY")
        else
          handle_async(type, body) || unexpected(type)
        end
      end
    end

    # Reads the end of a copy: `CommandComplete` (the row count) and
    # `ReadyForQuery`; an `ErrorResponse` is raised after the latter.
    private def finish_copy : Int64
      rows = 0_i64
      error = nil
      loop do
        type, body = read_message
        case type
        when 'C' then rows = ExecResult.from_tag(parse { Messages::CommandComplete.from_slice(body) }.tag).rows_affected
        when 'd', 'c'
        when 'E' then error ||= parse { query_error(body) }
        when 'Z'
          @transaction_status = ready_status(body)
          break
        else
          handle_async(type, body) || unexpected(type)
        end
      end
      raise error if error
      rows
    end

    # Writes one message: type, back-patched length, the block's body.
    private def write_message(type : Char, & : IO::Memory ->) : Nil
      @out.write_byte(type.ord.to_u8)
      start = @out.pos
      @out.write_bytes(0_i32, IO::ByteFormat::BigEndian)
      yield @out
      patch(start, (@out.pos - start).to_i32)
    end

    # :nodoc:
    #
    # For `CopyWriter`: sends *data* as one `CopyData`.
    def unsafe_copy_data(data : Bytes) : Nil
      write_message('d', &.write(data))
      flush
    end

    # :nodoc:
    #
    # For `CopyReader`: the next `CopyData` body (valid until the next
    # read), or nil at `CopyDone`.
    def unsafe_read_copy_data : Bytes?
      loop do
        type, body = read_message
        case type
        when 'd' then return body
        when 'c' then return nil
        when 'E'
          # The COPY failed mid-stream: the server goes straight to
          # `ReadyForQuery`. Read it so the session stays in step, then
          # raise; `CopyReader` remembers the failure.
          error = parse { query_error(body) }
          loop do
            t, b = read_message
            if t == 'Z'
              @transaction_status = ready_status(b)
              break
            end
          end
          raise error
        else
          handle_async(type, body) || unexpected(type)
        end
      end
    end
  end

  # :nodoc:
  #
  # The `IO` a `copy_from` block writes to: buffered into `CopyData`
  # messages of up to `Connection::COPY_CHUNK` bytes.
  class CopyWriter < IO
    def initialize(@connection : Connection)
      @buffer = IO::Memory.new(Connection::COPY_CHUNK)
    end

    def write(slice : Bytes) : Nil
      return if slice.empty?
      if @buffer.pos + slice.size > Connection::COPY_CHUNK
        flush
        return @connection.unsafe_copy_data(slice) if slice.size >= Connection::COPY_CHUNK
      end
      @buffer.write(slice)
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("a COPY FROM STDIN stream is write-only")
    end

    def flush : Nil
      return if @buffer.pos == 0
      @connection.unsafe_copy_data(@buffer.to_slice)
      @buffer.clear
    end
  end

  # :nodoc:
  #
  # The `IO` a `copy_to` block reads from, one `CopyData` at a time.
  class CopyReader < IO
    @chunk = Bytes.empty
    @done = false
    # The failure that ended the stream: a server error, or the
    # `IO::TimeoutError` of a cancelled copy (the session is already at
    # `ReadyForQuery` then), or a connection failure.
    getter failure : Exception?

    def initialize(@connection : Connection)
    end

    def read(slice : Bytes) : Int32
      while @chunk.empty?
        return 0 if @done
        if data = next_data
          @chunk = data
        else
          @done = true
        end
      end
      count = {slice.size, @chunk.size}.min
      @chunk[0, count].copy_to(slice)
      @chunk += count
      count
    end

    def write(slice : Bytes) : NoReturn
      raise IO::Error.new("a COPY TO STDOUT stream is read-only")
    end

    def skip_to_end : Nil
      until @done
        @done = true unless next_data
      end
      @chunk = Bytes.empty
    end

    private def next_data : Bytes?
      @connection.unsafe_read_copy_data
    rescue ex
      @done = true
      @failure = ex
      raise ex
    end
  end

  # Writes rows for `Connection#copy_rows` in the binary COPY format.
  class CopyRows
    # :nodoc:
    #
    # *columns* is stored as an Array: an `Indexable(String)` ivar fed tuples
    # of different sizes crashes the 1.21 compiler (see
    # .agent-context/notes/compiler-crash-indexable-ivar-tuples.cr).
    def initialize(@io : IO, columns : Indexable(String), @oids : Array(UInt32))
      @columns = columns.to_a
      @value = IO::Memory.new
    end

    # Writes one row. *values* go to the columns in order; `nil` is NULL.
    # Raises `ArgumentError` for the wrong number of values and
    # `EncodeError` for a value that cannot be sent in binary for its
    # column's type.
    def row(*values) : Nil
      unless values.size == @oids.size
        raise ArgumentError.new("copy_rows expects #{@oids.size} values per row, got #{values.size}")
      end
      @io.write_bytes(values.size.to_i16, IO::ByteFormat::BigEndian)
      values.each_with_index do |value, i|
        if value.nil?
          @io.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
        else
          @value.clear
          format = begin
            Codec.encode(@value, @oids[i], value)
          rescue ex : EncodeError
            raise EncodeError.new("column #{@columns[i]}: #{ex.message}")
          end
          unless format == Codec::BINARY
            raise EncodeError.new("column #{@columns[i]}: binary COPY cannot send #{value.class} as #{OID.name(@oids[i])}")
          end
          @io.write_bytes(@value.pos.to_i32, IO::ByteFormat::BigEndian)
          @io.write(@value.to_slice)
        end
      end
    end
  end
end
