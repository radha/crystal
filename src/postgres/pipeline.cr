require "./connection"

module Postgres
  # The result of one pipelined query, available once the pipeline ran.
  class Future(T)
    @value : T?
    @set = false
    @error : Exception?

    # The query's result. Raises the query's own error (`QueryError`,
    # `EncodeError`, `DecodeError`, `NoRowsError`, `IO::TimeoutError`, ...),
    # or `Error` if the pipeline has not run yet.
    def value : T
      if error = @error
        raise error
      end
      raise Error.new("the pipeline has not run yet") unless @set
      @value.as(T)
    end

    # Whether the query failed (`value` would raise).
    def failed? : Bool
      !@error.nil?
    end

    # :nodoc:
    def resolve(value : T) : Nil
      @value = value
      @set = true
    end

    # :nodoc:
    def reject(error : Exception) : Nil
      @error ||= error
    end
  end

  # Queues queries for `Connection#pipeline`. Each method returns a
  # `Future` that is resolved when the pipeline runs.
  class Pipeline
    # :nodoc:
    abstract class Op
      getter sql : String
      property statement : PreparedStatement?

      def initialize(@sql : String)
      end

      abstract def arity : Int32
      abstract def write_bind(buf : IO::Memory, statement : PreparedStatement) : Nil
      abstract def row(reader : RowReader) : Nil
      abstract def complete(result : ExecResult) : Nil
      abstract def reject(error : Exception) : Nil
    end

    # :nodoc:
    class ExecOp(A) < Op
      getter future = Future(ExecResult).new

      def initialize(sql : String, @args : A)
        super(sql)
      end

      def arity : Int32
        @args.size
      end

      def write_bind(buf : IO::Memory, statement : PreparedStatement) : Nil
        Connection.write_bind(buf, statement, @args)
      end

      def row(reader : RowReader) : Nil
      end

      def complete(result : ExecResult) : Nil
        @future.resolve(result)
      end

      def reject(error : Exception) : Nil
        @future.reject(error)
      end
    end

    # :nodoc:
    class AllOp(A, T) < Op
      getter future = Future(Array(T)).new
      @rows = [] of T

      def initialize(sql : String, @args : A)
        super(sql)
      end

      def arity : Int32
        @args.size
      end

      def write_bind(buf : IO::Memory, statement : PreparedStatement) : Nil
        Connection.write_bind(buf, statement, @args)
      end

      def row(reader : RowReader) : Nil
        @rows << Connection.decode_row(reader, T)
      end

      def complete(result : ExecResult) : Nil
        @future.resolve(@rows)
      end

      def reject(error : Exception) : Nil
        @future.reject(error)
      end
    end

    # :nodoc:
    #
    # `query_one` (*required*) and `query_one?`: the first row, or
    # `NoRowsError` / nil for none.
    class OneOp(A, T, R) < Op
      getter future = Future(R).new
      @value : T?
      @found = false

      def initialize(sql : String, @args : A, @required : Bool)
        super(sql)
      end

      def arity : Int32
        @args.size
      end

      def write_bind(buf : IO::Memory, statement : PreparedStatement) : Nil
        Connection.write_bind(buf, statement, @args)
      end

      def row(reader : RowReader) : Nil
        return if @found
        @value = Connection.decode_row(reader, T)
        @found = true
      end

      def complete(result : ExecResult) : Nil
        if @found
          @future.resolve(@value.as(R))
        elsif @required
          @future.reject(NoRowsError.new("no rows returned by #{sql.inspect}"))
        else
          # Only `query_one?` (R nilable) gets here: `@required` is true
          # for `query_one`.
          {% if R.nilable? %}
            @future.resolve(nil)
          {% end %}
        end
      end

      def reject(error : Exception) : Nil
        @future.reject(error)
      end
    end

    # :nodoc:
    getter ops = [] of Op

    ::Postgres.def_tuple_queries(query_all, query_one, query_one?)

    # Queues `Connection#exec` with arguments (extended protocol).
    def exec(sql : String, *args) : Future(ExecResult)
      op = ExecOp.new(sql, args)
      @ops << op
      op.future
    end

    # Queues `Connection#query_all`.
    def query_all(sql : String, *args, as type : T.class) : Future(Array(T)) forall T
      op = AllOp(typeof(args), T).new(sql, args)
      @ops << op
      op.future
    end

    # Queues `Connection#query_one`; the future raises `NoRowsError` when
    # there is no row.
    def query_one(sql : String, *args, as type : T.class) : Future(T) forall T
      op = OneOp(typeof(args), T, T).new(sql, args, true)
      @ops << op
      op.future
    end

    # Queues `Connection#query_one?`.
    def query_one?(sql : String, *args, as type : T.class) : Future(T?) forall T
      op = OneOp(typeof(args), T, T?).new(sql, args, false)
      @ops << op
      op.future
    end
  end

  class Connection
    # Runs the queries the block queues in (at most) two round trips: one
    # that prepares every statement not yet cached, one that executes
    # every query. Each query is independent, as if run on its own: a
    # failing query fails only its `Future`, and the others still run
    # (wrap the pipeline in `transaction` for all-or-nothing).
    #
    # ```
    # user = nil
    # count = nil
    # conn.pipeline do |p|
    #   user = p.query_one("select * from users where id = $1", 1, as: User)
    #   count = p.query_one("select count(*) from orders", as: Int64)
    #   p.exec("update users set seen_at = now() where id = $1", 1)
    # end
    # user.not_nil!.value
    # ```
    #
    # Futures are resolved when the call returns; nothing is sent if the
    # block raises. A statement the server dropped (after `DISCARD ALL`)
    # fails its future instead of being re-prepared; the next use
    # re-prepares it. A lost connection fails every unresolved future and
    # is raised.
    def pipeline(& : Pipeline ->) : Nil
      pipeline = Pipeline.new
      yield pipeline
      ops = pipeline.ops
      return if ops.empty?
      enter
      begin
        run_pipeline(ops)
      rescue ex
        ops.each(&.reject(ex))
        raise ex
      ensure
        leave
      end
    end

    private def run_pipeline(ops : Array(Pipeline::Op)) : Nil
      @hold_closes = true
      run_pipeline_rounds(ops)
    ensure
      @hold_closes = false
    end

    private def run_pipeline_rounds(ops : Array(Pipeline::Op)) : Nil
      # Round 1: prepare each distinct statement not in the cache, each
      # with its own Sync so one bad statement fails only its queries.
      statements = {} of String => PreparedStatement
      temporary = [] of String
      to_prepare = [] of {String, String}
      ops.each do |op|
        next if statements.has_key?(op.sql) || to_prepare.any? { |sql, _| sql == op.sql }
        if @cache.enabled? && (cached = @cache[op.sql])
          statements[op.sql] = cached
        else
          name = @cache.next_name
          temporary << name unless @cache.enabled?
          to_prepare << {op.sql, name}
        end
      end
      unless to_prepare.empty?
        flush_closes(force: true) # queued before this pipeline: safe to send
        to_prepare.each do |sql, name|
          Messages::Parse.new(name: name, query: sql, oids: [] of UInt32).write(@out)
          Messages::Describe.new(kind: 'S'.ord.to_u8, name: name).write(@out)
          @out.write(Messages::SYNC)
        end
        flush
        described = [] of {String, PreparedStatement}
        to_prepare.each do |sql, name|
          statement, error = read_prepared(name)
          if statement
            described << {sql, statement}
          else
            ops.each { |op| op.reject(error.not_nil!) if op.sql == sql }
          end
        end
        # One introspection for every new statement, then rebuild them with
        # what it learned (domain parameters, composite columns).
        introspect(described.flat_map { |_, s| s.param_oids + s.columns.map(&.type_oid) })
        described.each do |sql, raw|
          statement = PreparedStatement.new(raw.name, raw.param_oids, raw.columns, @types)
          statements[sql] = statement
          @cache.add(sql, statement) if @cache.enabled?
        end
      end

      # Round 2: Bind/Execute/Sync per query; queued closes (including
      # evictions caused by round 1) only after every query.
      sent = [] of Pipeline::Op
      scratch = IO::Memory.new
      ops.each do |op|
        next unless statement = statements[op.sql]?
        unless op.arity == statement.param_oids.size
          op.reject(ArgumentError.new("query expects #{statement.param_oids.size} parameters, got #{op.arity}"))
          next
        end
        scratch.clear
        begin
          op.write_bind(scratch, statement)
        rescue ex
          # Any encoder failure (a user `to_pg` too) fails only this query;
          # its half-written Bind stays in the scratch buffer.
          op.reject(ex)
          next
        end
        op.statement = statement
        @out.write(scratch.to_slice)
        Messages::Execute.new(portal: "").write(@out)
        @out.write(Messages::SYNC)
        sent << op
      end
      temporary.each { |name| @cache.closes << name }
      closing = !@cache.closes.empty?
      if closing
        flush_closes(force: true)
        @out.write(Messages::SYNC)
      end
      flush unless sent.empty? && !closing

      reader = @reader ||= RowReader.new([] of Column)
      sent.each do |op|
        reader.reset(op.statement.not_nil!.columns)
        read_pipelined(op, reader)
      end
      read_until_ready if closing
    end

    # Reads one statement's `Parse`/`Describe`/`Sync` replies.
    private def read_prepared(name : String) : {PreparedStatement?, Exception?}
      param_oids = [] of UInt32
      columns = [] of Column
      error = nil
      loop do
        type, body = read_message
        case type
        when 't' then param_oids = parse { Messages::ParameterDescription.from_slice(body) }.oids
        when 'T'
          columns = parse { Messages::RowDescription.from_slice(body) }.columns.map do |c|
            Column.new(c.name, c.type_oid, c.table_oid, c.type_modifier, c.format)
          end
        when '1', '3', 'n'
        when 'E' then error ||= parse { query_error(body) }
        when 'Z'
          begin
            @transaction_status = ready_status(body)
          rescue ex : IO::TimeoutError
            # This statement's Parse was cancelled; the others' replies
            # follow and must still be read.
            error = ex
          end
          break
        else
          handle_async(type, body) || unexpected(type)
        end
      end
      return {nil, error} if error
      {PreparedStatement.new(name, param_oids, columns), nil}
    end

    # Reads one pipelined query's replies up to its `ReadyForQuery` and
    # settles its future. A timeout cancelled only this query.
    private def read_pipelined(op : Pipeline::Op, reader : RowReader) : Nil
      result = ExecResult.new("", 0_i64)
      failure = nil
      loop do
        type, body = read_message
        case type
        when 'D'
          next if failure
          parse { reader.load(body) }
          begin
            op.row(reader)
          rescue ex
            failure = ex
          end
        when 'C' then result = ExecResult.from_tag(parse { Messages::CommandComplete.from_slice(body) }.tag)
        when '2', '3', 'I', 'n', 's'
        when 'E'
          error = parse { query_error(body) }
          if (error.code == "26000" || error.code == "0A000") && (statement = op.statement) && !statement.name.empty?
            drop_stale(op.sql, statement, error)
          end
          failure ||= error
        when 'Z'
          begin
            @transaction_status = ready_status(body)
          rescue ex : IO::TimeoutError
            failure = ex
          end
          break
        else
          handle_async(type, body) || unexpected(type)
        end
      end
      if failure
        op.reject(failure)
      else
        op.complete(result)
      end
    end

    # Reads and discards replies up to the next `ReadyForQuery`.
    private def read_until_ready : Nil
      loop do
        type, body = read_message
        case type
        when 'Z'
          @transaction_status = ready_status(body)
          return
        when 'E', '3', 'C'
        else
          handle_async(type, body) || unexpected(type)
        end
      end
    end
  end

  class Client
    # Runs a pipeline on one borrowed connection; see
    # `Connection#pipeline`.
    def pipeline(& : Pipeline ->) : Nil
      borrow { |conn| conn.pipeline { |p| yield p } }
    end
  end
end
