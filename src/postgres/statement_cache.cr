module Postgres
  # :nodoc:
  #
  # A statement prepared on one connection: its server-side name, the
  # parameter types the server inferred and the result columns (with the
  # format codes the client asks for in `Bind`).
  class PreparedStatement
    getter name : String
    getter param_oids : Array(UInt32)
    getter columns : Array(Column)
    # `Bind`'s result-format codes: one `1` when every column is binary,
    # otherwise one code per column.
    getter result_formats : Array(Int16)

    def initialize(@name : String, @param_oids : Array(UInt32), columns : Array(Column))
      @columns = columns.map do |c|
        Column.new(c.name, c.type_oid, c.table_oid, c.type_modifier, OID.binary?(c.type_oid) ? 1_i16 : 0_i16)
      end
      @result_formats = if @columns.all?(&.binary?)
                          @columns.empty? ? [] of Int16 : [1_i16]
                        else
                          @columns.map(&.format)
                        end
    end
  end

  # :nodoc:
  #
  # Per-connection LRU of prepared statements keyed by SQL text. `Hash`
  # keeps insertion order, so a hit moves the entry to the end and an
  # eviction takes the first; evicted names wait in `closes` until the
  # connection sends their `Close` ahead of its next round trip.
  class StatementCache
    getter capacity : Int32
    getter closes = [] of String

    def initialize(@capacity : Int32)
      @entries = {} of String => PreparedStatement
      @counter = 0
    end

    def enabled? : Bool
      @capacity > 0
    end

    def size : Int32
      @entries.size
    end

    def [](sql : String) : PreparedStatement?
      if statement = @entries.delete(sql)
        @entries[sql] = statement
      end
    end

    def next_name : String
      "s#{@counter += 1}"
    end

    def add(sql : String, statement : PreparedStatement) : Nil
      @entries[sql] = statement
      while @entries.size > @capacity
        _, evicted = @entries.shift
        @closes << evicted.name
      end
    end

    # Forgets *sql* without closing it (the server no longer has it).
    def forget(sql : String) : Nil
      @entries.delete(sql)
    end

    # Forgets every statement and queues their `Close`.
    def clear : Nil
      @entries.each_value { |s| @closes << s.name }
      @entries.clear
    end

    # Forgets every statement without closing (after `DISCARD ALL`).
    def reset : Nil
      @entries.clear
    end
  end
end
