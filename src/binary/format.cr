require "./varint"
require "./frame"
require "./bit_order"

module Binary
  # Declarative layout for binary structs. See the module docs added in Task 10.
  module Format
    # :nodoc:
    annotation Entry
    end

    # Raised for malformed input or values that cannot be encoded.
    class Error < Binary::Error
    end

    # Raised when a `magic` value read from the input does not match.
    class MagicError < Error
      getter expected : Bytes
      getter actual : Bytes

      def initialize(type : String, @expected : Bytes, @actual : Bytes)
        super("#{type}: magic mismatch, expected #{@expected.hexstring} but read #{@actual.hexstring}")
      end
    end

    # Raised when a length or count prefix exceeds its `max:` or is negative.
    class SizeError < Error
    end

    # Default `max:` for byte lengths.
    DEFAULT_MAX_BYTES = Binary::Frame::DEFAULT_MAX_SIZE
    # Default `max:` for element counts.
    DEFAULT_MAX_COUNT = 16 * 1024 * 1024
    # Largest capacity an array is presized to from a count prefix.
    PRESIZE_LIMIT = 65_536

    # :nodoc:
    #
    # Runtime helpers called by generated code.
    module Codec
      def self.read_bool(io : IO) : Bool
        (io.read_byte || raise IO::EOFError.new) != 0
      end

      def self.write_bool(io : IO, value : Bool) : Nil
        io.write_byte(value ? 1_u8 : 0_u8)
      end

      # `typeof(T.new(0).value)` derives the enum's underlying integer type
      # without calling `T.values` (calling `.values` on a `T` resolved from a
      # `private enum` in a different file raises "undefined constant" — see
      # Task 2 report).
      def self.read_enum(io : IO, type : T.class, format : IO::ByteFormat) : T forall T
        T.new(io.read_bytes(typeof(T.new(0).value), format))
      end

      def self.write_enum(io : IO, value : Enum, format : IO::ByteFormat) : Nil
        io.write_bytes(value.value, format)
      end

      ZEROS = Bytes.new(64)

      def self.write_zeros(io : IO, count : Int32) : Nil
        while count > 0
          n = Math.min(count, ZEROS.size)
          io.write(ZEROS[0, n])
          count -= n
        end
      end

      def self.check_magic(actual : Bytes, expected : Bytes, type : String) : Nil
        raise MagicError.new(type, expected, actual) unless actual == expected
      end

      def self.read_magic(io : IO, expected : Bytes, type : String) : Nil
        actual = Bytes.new(expected.size)
        io.read_fully(actual)
        check_magic(actual, expected, type)
      end

      # Placeholder value for derived fields in the keyword constructor.
      def self.zero(type : T.class) : T forall T
        {% if T < ::Enum %}
          T.new(typeof(T.new(0).value).zero)
        {% elsif T == ::Bool %}
          false
        {% else %}
          T.zero
        {% end %}
      end
    end

    # Sets the default byte order for every multi-byte field of this format.
    # One of `:big` (default), `:little` or `:native`.
    macro endian(value)
      {% raise "Binary::Format: endian must be :big, :little or :native, not #{value}" unless [:big, :little, :native].includes?(value) %}
      @[::Binary::Format::Entry(kind: :endian, value: {{value}})]
      private def __binary_directive_endian; end
    end

    # Skips *size* bytes on read and writes *size* zero bytes.
    macro pad(size)
      {% raise "Binary::Format: `pad` expects a positive integer literal, got `#{size}`" unless size.is_a?(NumberLiteral) && size > 0 %}
      @[::Binary::Format::Entry(kind: :pad, size: {{size}})]
      private def __binary_entry_pad_{{@type.methods.size}}; end
    end

    # Pads to the next multiple of *size* bytes counted from the start of the
    # record. Every entry before it must have a fixed width.
    macro align(size)
      {% raise "Binary::Format: `align` expects a positive integer literal, got `#{size}`" unless size.is_a?(NumberLiteral) && size > 0 %}
      @[::Binary::Format::Entry(kind: :align, size: {{size}})]
      private def __binary_entry_align_{{@type.methods.size}}; end
    end

    # Declares constant bytes: a `String` (ASCII only), `Bytes[...]`, or an
    # integer literal with a type suffix (written in the type's endian).
    # Read asserts the bytes and raises `MagicError` on mismatch.
    macro magic(value)
      {% if value.is_a?(StringLiteral) %}
        {% raise "Binary::Format: a String magic must be ASCII, use Bytes[...] otherwise" unless value =~ /\A[\x00-\x7f]*\z/ %}
      {% elsif value.is_a?(NumberLiteral) %}
        {% raise "Binary::Format: an integer magic needs a type suffix, e.g. 0x89504E47_u32" unless value.kind.id.stringify =~ /\A[ui](8|16|32|64|128)\z/ %}
      {% elsif !(value.is_a?(Call) && value.name == "[]") %}
        {% raise "Binary::Format: magic must be a String, Bytes[...] or a suffixed integer literal, got `#{value}`" %}
      {% end %}
      @[::Binary::Format::Entry(kind: :magic, value: {{value}})]
      private def __binary_entry_magic_{{@type.methods.size}}; end
    end

    # Declares the next field of the layout. See the module docs for options.
    macro field(decl, **opts)
      {% raise "Binary::Format: `field` expects `name : Type`, got `#{decl}`" unless decl.is_a?(TypeDeclaration) %}
      {% stored = decl.type.is_a?(Union) ? "::Union(#{decl.type.types.splat})".id : decl.type %}
      @{{decl.var}} : {{decl.type}}

      def {{decl.var}} : {{decl.type}}
        @{{decl.var}}
      end

      @[::Binary::Format::Entry(kind: :field, name: {{decl.var.symbolize}}, type: {{stored}}, has_default: {{!decl.value.is_a?(Nop)}}, default: {{decl.value.is_a?(Nop) ? nil : decl.value}}, {{opts.double_splat}})]
      private def __binary_entry_{{decl.var}}; end
    end

    macro included
      macro finished
        __binary_stage1
      end
    end

    # :nodoc:
    #
    # Stage 1 runs in `macro finished`. It cannot evaluate `sizeof` on a type
    # held in a macro variable, so it emits stage 2 with literal type paths.
    macro __binary_stage1
      {% enum_entries = [] of Nil %}
      {% for m in @type.methods %}
        {% a = m.annotation(::Binary::Format::Entry) %}
        {% if a && a[:kind] == :field %}
          {% t = a[:type].resolve %}
          {% if t.nilable? %}
            {% t = t.union_types.reject { |u| u == ::Nil }[0] %}
          {% end %}
          {% if t < ::Enum %}
            {% enum_entries << {a[:name].id, t} %}
          {% elsif (t.name.starts_with?("StaticArray(") || t.name.starts_with?("Array(")) && t.type_vars[0] < ::Enum %}
            {% enum_entries << {"#{a[:name].id}__elem".id, t.type_vars[0]} %}
          {% end %}
        {% end %}
      {% end %}
      macro __binary_stage2
        \{% widths = { __binary_none: 0, {% for pair in enum_entries %} {{pair[0]}}: sizeof({{pair[1]}}), {% end %} } %}
        __binary_generate(\{{ widths }})
      end
      __binary_stage2
    end

    # :nodoc:
    macro __binary_read_scalar(io, cat, type, format, opts)
      {% if cat == :int || cat == :float %}
        {{io}}.read_bytes({{type}}, {{format}})
      {% elsif cat == :bool %}
        ::Binary::Format::Codec.read_bool({{io}})
      {% elsif cat == :enum %}
        ::Binary::Format::Codec.read_enum({{io}}, {{type}}, {{format}})
      {% else %}
        {% raise "Binary::Format: cannot read #{cat}" %}
      {% end %}
    end

    # :nodoc:
    macro __binary_write_scalar(io, cat, type, format, value, opts)
      {% if cat == :int || cat == :float %}
        {{io}}.write_bytes({{value}}, {{format}})
      {% elsif cat == :bool %}
        ::Binary::Format::Codec.write_bool({{io}}, {{value}})
      {% elsif cat == :enum %}
        ::Binary::Format::Codec.write_enum({{io}}, {{value}}, {{format}})
      {% else %}
        {% raise "Binary::Format: cannot write #{cat}" %}
      {% end %}
    end

    # :nodoc:
    macro __binary_size_scalar(cat, type, value, opts)
      {% if cat == :int || cat == :float || cat == :bool || cat == :enum %}
        {{opts[:width]}}
      {% else %}
        {% raise "Binary::Format: cannot size #{cat}" %}
      {% end %}
    end

    # :nodoc:
    macro __binary_generate(widths)
      {% type_endian = :big %}
      {% raw = [] of Nil %}
      {% for m in @type.methods %}
        {% a = m.annotation(::Binary::Format::Entry) %}
        {% if a %}
          {% if a[:kind] == :endian %}
            {% type_endian = a[:value] %}
          {% else %}
            {% raw << a %}
          {% end %}
        {% end %}
      {% end %}

      {%
        type_name = @type.name
        int_widths = {"Int8" => 1, "UInt8" => 1, "Int16" => 2, "UInt16" => 2, "Int32" => 4, "UInt32" => 4, "Int64" => 8, "UInt64" => 8, "Int128" => 16, "UInt128" => 16}
        float_widths = {"Float32" => 4, "Float64" => 8}
        magic_widths = {"i8" => 1, "u8" => 1, "i16" => 2, "u16" => 2, "i32" => 4, "u32" => 4, "i64" => 8, "u64" => 8, "i128" => 16, "u128" => 16}
        formats = {big: "::IO::ByteFormat::BigEndian".id, little: "::IO::ByteFormat::LittleEndian".id, native: "::IO::ByteFormat::SystemEndian".id}
        internal_keys = ["kind", "name", "type", "has_default", "default"]
        entries = [] of Nil
        offset = 0
        fixed = true
      %}

      {% for a in raw %}
        {% e = {} of Nil => Nil %}
        {% e[:kind] = a[:kind] %}
        {% e[:width] = nil %}
        {% e[:derived] = false %}
        {% e[:write_value] = nil %}
        {% if a[:kind] == :field %}
          {% e[:name] = a[:name].id %}
          {% e[:label] = "#{type_name}##{a[:name].id}" %}
          {% e[:has_default] = a[:has_default] %}
          {% e[:default] = a[:default] %}
          {% decl = a[:type].resolve %}
          {% e[:decl] = decl %}
          {% e[:nilable] = decl.nilable? %}
          {% if decl.nilable? %}
            {% inner = decl.union_types.reject { |u| u == ::Nil } %}
            {% raise "#{e[:label].id}: only `T?` unions are supported" unless inner.size == 1 %}
            {% t = inner[0] %}
          {% else %}
            {% t = decl %}
          {% end %}
          {% e[:type] = t %}
          {% e[:endian] = a[:endian] || type_endian %}
          {% raise "#{e[:label].id}: endian must be :big, :little or :native" unless [:big, :little, :native].includes?(e[:endian]) %}
          {% e[:format] = formats[e[:endian].id.symbolize] %}
          {% e[:signed] = false %}
          {% allowed = ["endian"] %}
          {% tname = t.name.stringify %}
          {% if t < ::Int && int_widths[tname] %}
            {% e[:cat] = :int %}
            {% e[:width] = int_widths[tname] %}
            {% e[:signed] = tname.starts_with?("Int") %}
          {% elsif float_widths[tname] %}
            {% e[:cat] = :float %}
            {% e[:width] = float_widths[tname] %}
          {% elsif t == ::Bool %}
            {% e[:cat] = :bool %}
            {% e[:width] = 1 %}
          {% elsif t < ::Enum %}
            {% e[:cat] = :enum %}
            {% e[:width] = widths[e[:name]] %}
          {% else %}
            {% raise "#{e[:label].id}: unsupported field type #{t}" %}
          {% end %}
          {% for key, _v in a.named_args %}
            {% ks = key.id.stringify %}
            {% unless internal_keys.includes?(ks) || allowed.includes?(ks) %}
              {% raise "#{e[:label].id}: option `#{ks.id}:` is not valid for a #{t} field (allowed: #{allowed.join(", ").id})" %}
            {% end %}
          {% end %}
          {% e[:opts] = {label: e[:label], width: e[:width], signed: e[:signed]} %}
        {% elsif a[:kind] == :pad %}
          {% e[:width] = a[:size] %}
        {% elsif a[:kind] == :align %}
          {% raise "#{type_name.id}: `align #{a[:size]}` needs every preceding entry to have a fixed width" unless offset %}
          {% e[:kind] = :pad %}
          {% e[:width] = (a[:size] - offset % a[:size]) % a[:size] %}
        {% elsif a[:kind] == :magic %}
          {% v = a[:value] %}
          {% e[:index] = entries.size %}
          {% if v.is_a?(StringLiteral) %}
            {% e[:width] = v.size %}
            {% e[:const_expr] = "#{v}.to_slice".id %}
          {% elsif v.is_a?(NumberLiteral) %}
            {% e[:width] = magic_widths[v.kind.id.stringify] %}
            {% e[:const_expr] = "(::IO::Memory.new(#{e[:width]}).tap { |m| m.write_bytes(#{v}, #{formats[type_endian]}) }.to_slice)".id %}
          {% else %}
            {% e[:width] = v.args.size %}
            {% e[:const_expr] = v %}
          {% end %}
        {% else %}
          {% raise "Binary::Format: unknown entry kind #{a[:kind]}" %}
        {% end %}
        {% if e[:width].nil? %}
          {% fixed = false %}
          {% offset = nil %}
        {% elsif offset %}
          {% e[:offset] = offset %}
          {% offset = offset + e[:width] %}
        {% end %}
        {% entries << e %}
      {% end %}

      {% fields = entries.select { |x| x[:kind] == :field } %}
      {% plain = fields.reject { |x| x[:derived] } %}

      # :nodoc:
      BINARY_FORMAT_FIXED = {{fixed}}

      {% for e in entries %}
        {% if e[:kind] == :magic %}
          # :nodoc:
          BINARY_MAGIC_{{e[:index]}} = {{e[:const_expr]}}
        {% end %}
      {% end %}

      # Returns `true` if every field has a compile-time width.
      def self.fixed_size? : Bool
        BINARY_FORMAT_FIXED
      end

      {% for e in plain %}
        def {{e[:name]}}=(value : {{e[:decl]}}) : {{e[:decl]}}
          @{{e[:name]}} = value
        end
      {% end %}

      {% params = plain.map { |x| "@#{x[:name]} : #{x[:decl]}#{(x[:has_default] ? " = #{x[:default]}" : (x[:nilable] ? " = nil" : "")).id}" } %}
      {% if params.empty? %}
        def initialize
          {% for e in fields.select { |x| x[:derived] } %}
            @{{e[:name]}} = ::Binary::Format::Codec.zero({{e[:type]}})
          {% end %}
        end
      {% else %}
        def initialize(*, {{params.join(", ").id}})
          {% for e in fields.select { |x| x[:derived] } %}
            @{{e[:name]}} = ::Binary::Format::Codec.zero({{e[:type]}})
          {% end %}
        end
      {% end %}

      # Reads one record from *io*. Raises `IO::EOFError` on truncated input.
      def self.read(io : IO) : self
        new(__binary_io: io)
      end

      # Parses one record from the start of *bytes*.
      def self.from_slice(bytes : Bytes) : self
        read(::IO::Memory.new(bytes, writable: false))
      end

      # Parses one record starting at *offset* and returns it with the number
      # of bytes consumed.
      def self.from_slice(bytes : Bytes, offset : Int) : {self, Int32}
        io = ::IO::Memory.new(bytes + offset, writable: false)
        {read(io), io.pos.to_i32}
      end

      # :nodoc:
      def initialize(*, __binary_io __io : IO)
        {% for e in entries %}
          {% if e[:kind] == :pad %}
            {% if e[:width] > 0 %} __io.skip({{e[:width]}}) {% end %}
          {% elsif e[:kind] == :magic %}
            ::Binary::Format::Codec.read_magic(__io, BINARY_MAGIC_{{e[:index]}}, {{type_name.stringify}})
          {% elsif e[:kind] == :field %}
            {{e[:name]}} = __binary_read_scalar(__io, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, {{e[:opts]}})
          {% end %}
        {% end %}
        {% for e in fields %}
          @{{e[:name]}} = {{e[:name]}}
        {% end %}
      end

      # Writes this record to *io*.
      def write(__io : IO) : Nil
        {% for e in entries %}
          {% if e[:kind] == :pad %}
            {% if e[:width] > 0 %} ::Binary::Format::Codec.write_zeros(__io, {{e[:width]}}) {% end %}
          {% elsif e[:kind] == :magic %}
            __io.write(BINARY_MAGIC_{{e[:index]}})
          {% elsif e[:kind] == :field %}
            __binary_write_scalar(__io, {{e[:cat]}}, {{e[:type]}}, {{e[:format]}}, {{e[:write_value] || "@#{e[:name]}".id}}, {{e[:opts]}})
          {% end %}
        {% end %}
      end

      # Returns the encoded size in bytes without writing anything.
      def byte_size : Int32
        __binary_size = 0
        {% for e in entries %}
          {% if e[:kind] == :field %}
            __binary_size += __binary_size_scalar({{e[:cat]}}, {{e[:type]}}, {{e[:write_value] || "@#{e[:name]}".id}}, {{e[:opts]}})
          {% else %}
            __binary_size += {{e[:width]}}
          {% end %}
        {% end %}
        __binary_size
      end

      # Returns this record encoded into a new `Bytes` of exactly `byte_size`.
      def to_slice : Bytes
        bytes = Bytes.new(byte_size)
        write(::IO::Memory.new(bytes))
        bytes
      end
    end
  end
end
