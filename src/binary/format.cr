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

      def self.check_size(size : Int, max : Int32, label : String) : Int32
        if size < 0 || size > max
          raise SizeError.new("#{label}: size #{size} is outside 0..#{max}")
        end
        size.to_i32
      end

      def self.read_string(io : IO, size : Int, max : Int32, label : String) : String
        io.read_string(check_size(size, max, label))
      end

      def self.read_cstring(io : IO, label : String) : String
        str = io.gets('\0', chomp: false) || raise IO::EOFError.new
        raise IO::EOFError.new unless str.ends_with?('\0')
        str.byte_slice(0, str.bytesize - 1)
      end

      def self.read_bytes(io : IO, size : Int, max : Int32, label : String) : Bytes
        buf = Bytes.new(check_size(size, max, label))
        io.read_fully(buf)
        buf
      end

      def self.read_rest_bytes(io : IO, max : Int32, label : String) : Bytes
        if io.is_a?(IO::Sized)
          read_bytes(io, io.read_remaining, max, label)
        else
          mem = IO::Memory.new
          IO.copy(io, mem, max.to_i64 + 1)
          check_size(mem.size, max, label)
          mem.to_slice
        end
      end

      def self.read_rest_string(io : IO, max : Int32, label : String) : String
        String.new(read_rest_bytes(io, max, label))
      end

      def self.write_cstring(io : IO, value : String, label : String) : Nil
        raise Error.new("#{label}: string contains a NUL byte") if value.byte_index(0_u8)
        io.write(value.to_slice)
        io.write_byte(0_u8)
      end

      def self.write_exact(io : IO, value : Bytes, size : Int, label : String) : Nil
        raise Error.new("#{label}: expected #{size} bytes but the value has #{value.size}") unless value.size == size
        io.write(value)
      end

      def self.check_count(count : Int, max : Int32, label : String) : Int32
        if count < 0 || count > max
          raise SizeError.new("#{label}: count #{count} is outside 0..#{max}")
        end
        count.to_i32
      end

      def self.check_exact_count(actual : Int, expected : Int, label : String) : Nil
        raise Error.new("#{label}: expected #{expected} elements but the value has #{actual}") unless actual == expected
      end

      def self.rest?(io : IO, label : String) : Bool
        peek = io.peek
        if peek.nil?
          raise Error.new("#{label}: `until: :eof` needs an IO that supports peek, #{io.class} does not")
        end
        !peek.empty?
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
    # integer literal with a type suffix other than `_i32` (write `_u32` for
    # a 4-byte magic), written in the type's endian. Read asserts the bytes
    # and raises `MagicError` on mismatch.
    macro magic(value)
      {% if value.is_a?(StringLiteral) %}
        {% raise "Binary::Format: a String magic must be ASCII, use Bytes[...] otherwise" unless value =~ /\A[\x00-\x7f]*\z/ %}
      {% elsif value.is_a?(NumberLiteral) %}
        {% raise "Binary::Format: an integer magic needs an explicit type suffix other than _i32 (an unsuffixed literal is Int32 too), e.g. 0x89504E47_u32" unless value.kind.id.stringify =~ /\A[ui](8|16|64|128)\z|\Au32\z/ %}
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
      {% elsif cat == :string %}
        {% if opts[:mode] == :cstring %}
          ::Binary::Format::Codec.read_cstring({{io}}, {{opts[:label]}})
        {% elsif opts[:mode] == :rest %}
          ::Binary::Format::Codec.read_rest_string({{io}}, {{opts[:max]}}, {{opts[:label]}})
        {% else %}
          ::Binary::Format::Codec.read_string({{io}}, {{opts[:length]}}, {{opts[:max]}}, {{opts[:label]}})
        {% end %}
      {% elsif cat == :bytes %}
        {% if opts[:mode] == :rest %}
          ::Binary::Format::Codec.read_rest_bytes({{io}}, {{opts[:max]}}, {{opts[:label]}})
        {% else %}
          ::Binary::Format::Codec.read_bytes({{io}}, {{opts[:length]}}, {{opts[:max]}}, {{opts[:label]}})
        {% end %}
      {% elsif cat == :nested %}
        {{type}}.read({{io}})
      {% elsif cat == :static_array %}
        {{type}}.new { __binary_read_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:eopts]}}) }
      {% elsif cat == :array %}
        begin
          {% if opts[:amode] == :rest %}
            %arr = ::Array({{opts[:elem]}}).new
            while ::Binary::Format::Codec.rest?({{io}}, {{opts[:label]}})
              %arr << __binary_read_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:eopts]}})
            end
          {% elsif opts[:amode] == :sentinel %}
            %arr = ::Array({{opts[:elem]}}).new
            loop do
              %item = __binary_read_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:eopts]}})
              break if %item == {{opts[:sentinel]}}
              %arr << %item
            end
          {% else %}
            %count = ::Binary::Format::Codec.check_count({{opts[:count]}}, {{opts[:max]}}, {{opts[:label]}})
            %arr = ::Array({{opts[:elem]}}).new(::Math.min(%count, ::Binary::Format::PRESIZE_LIMIT))
            %count.times do
              %arr << __binary_read_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:eopts]}})
            end
          {% end %}
          %arr
        end
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
      {% elsif cat == :string || cat == :bytes %}
        {% if opts[:mode] == :cstring %}
          ::Binary::Format::Codec.write_cstring({{io}}, {{value}}, {{opts[:label]}})
        {% elsif opts[:mode] == :fixed || opts[:mode] == :length %}
          ::Binary::Format::Codec.write_exact({{io}}, {{value}}.to_slice, {{opts[:length]}}, {{opts[:label]}})
        {% else %}
          {{io}}.write({{value}}.to_slice)
        {% end %}
      {% elsif cat == :nested %}
        {{value}}.write({{io}})
      {% elsif cat == :static_array %}
        {{value}}.each { |%item| __binary_write_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, %item, {{opts[:eopts]}}) }
      {% elsif cat == :array %}
        {% if opts[:amode] == :fixed || opts[:amode] == :proc %}
          ::Binary::Format::Codec.check_exact_count({{value}}.size, {{opts[:count]}}, {{opts[:label]}})
        {% end %}
        {{value}}.each { |%item| __binary_write_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, %item, {{opts[:eopts]}}) }
        {% if opts[:amode] == :sentinel %}
          __binary_write_scalar({{io}}, {{opts[:ecat]}}, {{opts[:elem]}}, {{format}}, {{opts[:sentinel]}}, {{opts[:eopts]}})
        {% end %}
      {% else %}
        {% raise "Binary::Format: cannot write #{cat}" %}
      {% end %}
    end

    # :nodoc:
    macro __binary_size_scalar(cat, type, value, opts)
      {% if cat == :int || cat == :float || cat == :bool || cat == :enum %}
        {{opts[:width]}}
      {% elsif cat == :string %}
        {% if opts[:mode] == :cstring %}
          ({{value}}.bytesize &+ 1)
        {% else %}
          {{value}}.bytesize
        {% end %}
      {% elsif cat == :bytes %}
        {{value}}.size
      {% elsif cat == :nested %}
        {{value}}.byte_size
      {% elsif cat == :static_array || cat == :array %}
        ({% if opts[:ewidth] %}{{value}}.size &* {{opts[:ewidth]}}{% else %}{{value}}.sum(0) { |%item| __binary_size_scalar({{opts[:ecat]}}, {{opts[:elem]}}, %item, {{opts[:eopts]}}) }{% end %}{% if opts[:amode] == :sentinel %} &+ __binary_size_scalar({{opts[:ecat]}}, {{opts[:elem]}}, {{opts[:sentinel]}}, {{opts[:eopts]}}){% end %})
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
          {% elem = nil %}
          {% if tname.starts_with?("StaticArray(") || tname.starts_with?("Array(") %}
            {% elem = t.type_vars[0] %}
          {% end %}
          {% cats = [] of Nil %}
          {% ws = [] of Nil %}
          {% sg = [] of Nil %}
          {% for tt in (elem ? [t, elem] : [t]) %}
            {% tn = tt.name.stringify %}
            {% if tt < ::Int && int_widths[tn] %}
              {% cats << :int %}
              {% ws << int_widths[tn] %}
              {% sg << tn.starts_with?("Int") %}
            {% elsif float_widths[tn] %}
              {% cats << :float %}
              {% ws << float_widths[tn] %}
              {% sg << false %}
            {% elsif tt == ::Bool %}
              {% cats << :bool %}
              {% ws << 1 %}
              {% sg << false %}
            {% elsif tt < ::Enum %}
              {% cats << :enum %}
              {% ws << (cats.size == 1 ? widths[e[:name]] : widths["#{e[:name]}__elem".id]) %}
              {% sg << false %}
            {% elsif tt == ::String %}
              {% cats << :string %}
              {% ws << nil %}
              {% sg << false %}
            {% elsif tn == "Slice(UInt8)" %}
              {% cats << :bytes %}
              {% ws << nil %}
              {% sg << false %}
            {% elsif tn.starts_with?("StaticArray(") %}
              {% raise "#{e[:label].id}: arrays of arrays are not supported" unless cats.empty? %}
              {% cats << :static_array %}
              {% ws << nil %}
              {% sg << false %}
            {% elsif tn.starts_with?("Array(") %}
              {% raise "#{e[:label].id}: arrays of arrays are not supported" unless cats.empty? %}
              {% cats << :array %}
              {% ws << nil %}
              {% sg << false %}
            {% elsif tt <= ::Binary::Format %}
              {% raise "#{e[:label].id}: #{tt} must be defined before #{@type} because it is embedded in it" unless tt.has_constant?(:BINARY_FORMAT_FIXED) %}
              {% cats << :nested %}
              {% ws << (tt.constant(:BINARY_FORMAT_FIXED) ? tt.constant(:SIZE) : nil) %}
              {% sg << false %}
            {% else %}
              {% raise "#{e[:label].id}: unsupported field type #{tt}" %}
            {% end %}
          {% end %}
          {% e[:cat] = cats[0] %}
          {% e[:width] = ws[0] %}
          {% e[:signed] = sg[0] %}
          {% if e[:cat] == :string %}
            {% allowed = ["length", "cstring", "until", "max"] %}
          {% elsif e[:cat] == :bytes %}
            {% allowed = ["length", "until", "max"] %}
          {% elsif e[:cat] == :nested %}
            {% allowed = [] of Nil %}
          {% elsif e[:cat] == :static_array %}
            {% allowed = ["endian", "cstring", "length"] %}
          {% elsif e[:cat] == :array %}
            {% allowed = ["endian", "cstring", "length", "count", "until", "sentinel", "max"] %}
          {% end %}
          {% e[:mode] = nil %}
          {% e[:length] = nil %}
          {% e[:max] = nil %}
          {% if e[:cat] == :string || e[:cat] == :bytes %}
            {% modes = 0 %}
            {% modes = modes + 1 if a[:length] %}
            {% modes = modes + 1 if a[:cstring] %}
            {% modes = modes + 1 if a[:until] %}
            {% raise "#{e[:label].id}: needs exactly one of `length:`, `cstring: true` or `until: :eof`" unless modes == 1 %}
            {% raise "#{e[:label].id}: `until:` must be :eof" if a[:until] && a[:until] != :eof %}
            {% e[:max] = a[:max] || "::Binary::Format::DEFAULT_MAX_BYTES".id %}
            {% if a[:cstring] %}
              {% e[:mode] = :cstring %}
            {% elsif a[:until] %}
              {% e[:mode] = :rest %}
            {% elsif a[:length].is_a?(SymbolLiteral) %}
              {% e[:mode] = :ref %}
              {% e[:length_ref] = a[:length].id %}
              {% e[:length] = a[:length].id %}
            {% elsif a[:length].is_a?(NumberLiteral) %}
              {% e[:mode] = :fixed %}
              {% e[:length] = a[:length] %}
              {% e[:width] = a[:length] %}
            {% elsif a[:length].is_a?(ProcLiteral) %}
              {% e[:mode] = :length %}
              {% e[:length] = "(#{a[:length].body})".id %}
            {% else %}
              {% raise "#{e[:label].id}: `length:` must be a field name symbol, an integer literal or a `->{ }` block" %}
            {% end %}
          {% end %}
          {% e[:eopts] = nil %}
          {% e[:amode] = nil %}
          {% e[:count] = nil %}
          {% e[:sentinel] = nil %}
          {% if elem %}
            {% e[:elem] = elem %}
            {% e[:ecat] = cats[1] %}
            {% e[:ewidth] = ws[1] %}
            {% emode = nil %}
            {% elength = nil %}
            {% if e[:ecat] == :string %}
              {% if a[:cstring] %}
                {% emode = :cstring %}
              {% elsif a[:length].is_a?(NumberLiteral) %}
                {% emode = :fixed %}
                {% elength = a[:length] %}
                {% e[:ewidth] = a[:length] %}
              {% else %}
                {% raise "#{e[:label].id}: String elements need `cstring: true` or `length: <integer>`" %}
              {% end %}
            {% elsif e[:ecat] == :bytes %}
              {% raise "#{e[:label].id}: Bytes elements need `length: <integer>`" unless a[:length].is_a?(NumberLiteral) %}
              {% emode = :fixed %}
              {% elength = a[:length] %}
              {% e[:ewidth] = a[:length] %}
            {% elsif a[:cstring] || a[:length] %}
              {% raise "#{e[:label].id}: `cstring:`/`length:` only apply to String or Bytes elements" %}
            {% end %}
            {% e[:eopts] = {label: e[:label], width: e[:ewidth], signed: sg[1], mode: emode, length: elength, max: nil} %}
            {% if e[:cat] == :static_array %}
              {% e[:count] = t.type_vars[1] %}
              {% e[:width] = e[:ewidth] ? e[:ewidth] * t.type_vars[1] : nil %}
            {% else %}
              {% modes = 0 %}
              {% modes = modes + 1 if a[:count] %}
              {% modes = modes + 1 if a[:until] %}
              {% modes = modes + 1 if a[:sentinel] %}
              {% raise "#{e[:label].id}: needs exactly one of `count:`, `until: :eof` or `sentinel:`" unless modes == 1 %}
              {% raise "#{e[:label].id}: `until:` must be :eof" if a[:until] && a[:until] != :eof %}
              {% e[:max] = a[:max] || "::Binary::Format::DEFAULT_MAX_COUNT".id %}
              {% if a[:until] %}
                {% e[:amode] = :rest %}
              {% elsif a[:sentinel] %}
                {% e[:amode] = :sentinel %}
                {% e[:sentinel] = a[:sentinel] %}
              {% elsif a[:count].is_a?(SymbolLiteral) %}
                {% e[:amode] = :ref %}
                {% e[:count_ref] = a[:count].id %}
                {% e[:count] = a[:count].id %}
              {% elsif a[:count].is_a?(NumberLiteral) %}
                {% e[:amode] = :fixed %}
                {% e[:count] = a[:count] %}
                {% e[:width] = e[:ewidth] ? e[:ewidth] * a[:count] : nil %}
              {% elsif a[:count].is_a?(ProcLiteral) %}
                {% e[:amode] = :proc %}
                {% e[:count] = "(#{a[:count].body})".id %}
              {% else %}
                {% raise "#{e[:label].id}: `count:` must be a field name symbol, an integer literal or a `->{ }` block" %}
              {% end %}
            {% end %}
          {% end %}
          {% for key, _v in a.named_args %}
            {% ks = key.id.stringify %}
            {% unless internal_keys.includes?(ks) || allowed.includes?(ks) %}
              {% raise "#{e[:label].id}: option `#{ks.id}:` is not valid for a #{t} field (allowed: #{allowed.join(", ").id})" %}
            {% end %}
          {% end %}
          {% e[:opts] = {label: e[:label], width: e[:width], signed: e[:signed], mode: e[:mode], length: e[:length], max: e[:max], amode: e[:amode], count: e[:count], sentinel: e[:sentinel], elem: e[:elem], ecat: e[:ecat], ewidth: e[:ewidth], eopts: e[:eopts]} %}
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
        {% e[:pos] = entries.size %}
        {% entries << e %}
      {% end %}

      {% for e in entries %}
        {% if e[:length_ref] %}
          {% target = nil %}
          {% for x in entries %}
            {% target = x if x[:kind] == :field && x[:name] == e[:length_ref] %}
          {% end %}
          {% raise "#{e[:label].id}: `length: :#{e[:length_ref]}` names an unknown field" unless target %}
          {% raise "#{e[:label].id}: `length: :#{e[:length_ref]}` must name an integer field declared before it" unless target[:cat] == :int && target[:pos] < e[:pos] %}
          {% raise "#{target[:label].id}: a derived field cannot have a default value" if target[:has_default] %}
          {% target[:derived] = true %}
          {% measure = e[:cat] == :string ? "bytesize" : "size" %}
          {% if e[:nilable] %}
            {% target[:write_value] = "#{target[:type]}.new(#{e[:name]}.try(&.#{measure.id}) || 0)".id %}
          {% else %}
            {% target[:write_value] = "#{target[:type]}.new(#{e[:name]}.#{measure.id})".id %}
          {% end %}
        {% end %}
        {% if e[:count_ref] %}
          {% target = nil %}
          {% for x in entries %}
            {% target = x if x[:kind] == :field && x[:name] == e[:count_ref] %}
          {% end %}
          {% raise "#{e[:label].id}: `count: :#{e[:count_ref]}` names an unknown field" unless target %}
          {% raise "#{e[:label].id}: `count: :#{e[:count_ref]}` must name an integer field declared before it" unless target[:cat] == :int && target[:pos] < e[:pos] %}
          {% raise "#{target[:label].id}: a derived field cannot have a default value" if target[:has_default] %}
          {% target[:derived] = true %}
          {% if e[:nilable] %}
            {% target[:write_value] = "#{target[:type]}.new(#{e[:name]}.try(&.size) || 0)".id %}
          {% else %}
            {% target[:write_value] = "#{target[:type]}.new(#{e[:name]}.size)".id %}
          {% end %}
        {% end %}
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
          {% for e in fields.select { |x| x[:derived] } %}
            @{{e[:name]}} = {{e[:write_value]}}
          {% end %}
        end
      {% else %}
        def initialize(*, {{params.join(", ").id}})
          {% for e in fields.select { |x| x[:derived] } %}
            @{{e[:name]}} = ::Binary::Format::Codec.zero({{e[:type]}})
          {% end %}
          {% for e in fields.select { |x| x[:derived] } %}
            @{{e[:name]}} = {{e[:write_value]}}
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
