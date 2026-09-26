module Postgres
  # Customizes how `Serializable` maps an instance variable:
  # `key:` names the column (default: the variable name), `ignore: true`
  # skips it (it must have a default value).
  annotation Field
  end

  # Maps result rows onto a struct or class by column name.
  #
  # ```
  # struct User
  #   include Postgres::Serializable
  #   getter id : Int64
  #   getter name : String
  #   @[Postgres::Field(key: "email_address")]
  #   getter email : String?
  #   getter role : String = "member"
  # end
  #
  # db.query_all("select id, name, email_address from users", as: User)
  # ```
  #
  # Each instance variable reads the column of the same name (or the
  # `Postgres::Field` `key:`) with the decoding rules of `RowReader#read`.
  # When the result has no such column, a variable with a default value
  # keeps it, a nilable one is `nil`, and any other raises `DecodeError`.
  # Extra columns are ignored. The column lookup is done once per result,
  # not per row.
  module Serializable
    macro included
      # :nodoc:
      def self.from_pg_row(row : ::Postgres::RowReader) : self
        instance = allocate
        instance.initialize(__pg_row: row)
        ::GC.add_finalizer(instance) if instance.responds_to?(:finalize)
        instance
      end
    end

    # :nodoc:
    def initialize(*, __pg_row row : ::Postgres::RowReader)
      {% begin %}
        {% ivars = @type.instance_vars.reject { |iv| (ann = iv.annotation(::Postgres::Field)) && ann[:ignore] } %}
        %map = row.mapping do
          [
            {% for iv in ivars %}
              {% ann = iv.annotation(::Postgres::Field) %}
              row.column_index({{ (ann && ann[:key]) || iv.name.stringify }}),
            {% end %}
          ] of Int32
        end
        {% for iv, i in ivars %}
          {% ann = iv.annotation(::Postgres::Field) %}
          if (%col{i} = %map[{{ i }}]) >= 0
            @{{ iv.name }} = row.read(%col{i}, {{ iv.type }})
          else
            {% if iv.has_default_value? %}
              @{{ iv.name }} = {{ iv.default_value }}
            {% elsif iv.type.nilable? %}
              @{{ iv.name }} = nil
            {% else %}
              raise ::Postgres::DecodeError.new("no column {{ ((ann && ann[:key]) || iv.name.stringify).id }} for {{ @type }}.{{ iv.name }}")
            {% end %}
          end
        {% end %}
      {% end %}
    end
  end
end
