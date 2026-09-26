require "./type_map"

module Postgres
  # One column of a result, as the server described it.
  struct Column
    # The column name (`?column?` for an unnamed expression).
    getter name : String
    # The type OID (see `pg_type`).
    getter type_oid : UInt32
    # The source table's OID, or 0 for an expression.
    getter table_oid : UInt32
    # The type modifier (e.g. a varchar's length + 4), or -1.
    getter type_modifier : Int32
    # 1 when the column is transferred in binary, 0 in text.
    getter format : Int16
    # :nodoc:
    #
    # The OID the codec decodes this column as: `type_oid`, or for a domain
    # its base type, for a composite `record` (see `TypeMap`).
    getter codec_oid : UInt32
    # :nodoc:
    getter types : TypeMap?

    def initialize(@name : String, @type_oid : UInt32, @table_oid : UInt32 = 0_u32,
                   @type_modifier : Int32 = -1, @format : Int16 = 1_i16, @types : TypeMap? = nil)
      @codec_oid = @types.try(&.resolve_column(@type_oid)) || @type_oid
    end

    # Whether the column is transferred in binary.
    def binary? : Bool
      @format == 1
    end
  end

  # What a command reported when it completed.
  struct ExecResult
    # The command tag's verb, e.g. `"INSERT"`, `"UPDATE"`, `"CREATE TABLE"`.
    getter command : String
    # Rows inserted, updated, deleted, selected, copied, ...; 0 for
    # commands that report none.
    getter rows_affected : Int64

    def initialize(@command : String, @rows_affected : Int64)
    end

    # :nodoc:
    def self.from_tag(tag : String) : ExecResult
      parts = tag.split(' ')
      if parts.size > 1 && (n = parts.last.to_i64?)
        new(parts[0], n)
      else
        new(tag, 0_i64)
      end
    end
  end

  # One `DataRow` at a time, read in place from the connection's receive
  # buffer. Handed to `Serializable` constructors; it is valid only while
  # the row is being decoded.
  class RowReader
    # The result's columns.
    getter columns : Array(Column)

    @data = Bytes.empty
    @starts = [] of Int32
    @sizes = [] of Int32
    @mapping : Array(Int32)?

    def initialize(@columns : Array(Column))
    end

    # :nodoc:
    #
    # Reuses this reader (and its offset arrays) for another result.
    def reset(@columns : Array(Column)) : Nil
      @mapping = nil
    end

    # :nodoc:
    #
    # Parses a `DataRow` body: `Int16` count, then per column an `Int32`
    # length (-1 for NULL) and the bytes.
    def load(data : Bytes) : Nil
      raise ProtocolError.new("truncated DataRow") if data.size < 2
      count = IO::ByteFormat::BigEndian.decode(Int16, data).to_i
      unless count == @columns.size
        raise ProtocolError.new("DataRow has #{count} columns, RowDescription #{@columns.size}")
      end
      @starts.clear
      @sizes.clear
      pos = 2
      count.times do
        raise ProtocolError.new("truncated DataRow") if pos + 4 > data.size
        size = IO::ByteFormat::BigEndian.decode(Int32, data + pos)
        pos += 4
        @starts << pos
        @sizes << size
        if size > 0
          raise ProtocolError.new("truncated DataRow") if pos + size > data.size
          pos += size
        elsif size < -1
          raise ProtocolError.new("negative column length #{size}")
        end
      end
      @data = data
    end

    # The number of columns.
    def size : Int32
      @columns.size
    end

    # The index of the column called *name*, or -1.
    def column_index(name : String) : Int32
      @columns.index(&.name.==(name)) || -1
    end

    # Whether column *index* is SQL NULL.
    def null?(index : Int32) : Bool
      @sizes[index] < 0
    end

    # Decodes column *index* as *type*; a nilable *type* reads SQL NULL as
    # `nil`. Raises `DecodeError` for NULL into a non-nilable type or a
    # column type that does not fit.
    def read(index : Int32, type : T.class) : T forall T
      column = @columns[index]
      size = @sizes[index]
      {% if T.nilable? %}
        return nil if size < 0
        {% raise "Postgres: #{T} must be a single type or a single type plus Nil" unless T.union_types.size == 2 %}
        # `typeof` strips Nil without spelling the type, which a
        # file-private type (in the caller's file) would not allow.
        Codec.decode(@data[@starts[index], size], column, typeof(Pointer(T).null.value.not_nil!))
      {% else %}
        raise DecodeError.new("column #{column.name.inspect} is NULL but #{T} is not nilable") if size < 0
        Codec.decode(@data[@starts[index], size], column, T)
      {% end %}
    end

    # :nodoc:
    #
    # A per-result column mapping computed by the block on the first row
    # and reused for the rest (reset with the columns).
    def mapping(& : -> Array(Int32)) : Array(Int32)
      @mapping ||= yield
    end
  end
end

require "./type_map"

module Postgres
  # :nodoc:
  #
  # `{Int64, String}` (a tuple of types) → `Tuple(Int64, String)`.
  def self.tuple_type(types : Tuple(*T)) forall T
    # Built with `typeof` rather than by spelling the types, which
    # file-private types in the caller's file would not allow.
    {% begin %}
      typeof({ {% for i in 0...T.size %} ::Postgres.instance_of(types[{{ i }}]), {% end %} })
    {% end %}
  end

  # :nodoc:
  #
  # Only ever used inside `typeof`: the instance type of *type*.
  def self.instance_of(type : X.class) : X forall X
    Pointer(X).null.value # never evaluated: `typeof` only
  end

  # :nodoc:
  #
  # A nested tuple of types (`{Int32, {Int32, String}}`): the tuple type.
  def self.instance_of(types : Tuple)
    instance_of(tuple_type(types))
  end

  # :nodoc:
  #
  # Adds `as: {Type, ...}` overloads of the given query methods, each
  # returning tuples. `query_each` is handled separately (it yields).
  macro def_tuple_queries(*names)
    {% for name in names %}
      # Like the `as type : T.class` form, with rows read as a tuple of
      # *types* by column position: `as: {Int64, String?}`.
      def {{ name.id }}(sql : String, *args, as types : Tuple)
        {{ name.id }}(sql, *args, as: ::Postgres.tuple_type(types))
      end
    {% end %}
  end
end
