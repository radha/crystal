module Redis
  # Typed command methods shared by `Connection`, `Client` and `Pipeline`.
  #
  # An includer defines `call(args : Indexable)` and
  # `typed_call(args : Indexable, &block : Value -> T)`. On `Connection`
  # and `Client` a typed method returns `T`; on `Pipeline` it returns a
  # `Future(T)`. Method bodies here are written once and carry no explicit
  # return type for that reason.
  #
  # Blocking commands (`BLPOP`, `BRPOP`, `BLMOVE`, `WAIT`, ...) have no typed
  # method: on a multiplexed `Client` they would stall every other caller.
  # Run them through `Connection#call` on a dedicated connection.
  module Commands
    # Sends an arbitrary command and returns the raw `Value` (a `Future(Value)`
    # on a pipeline). Error replies are raised as `CommandError`.
    #
    # ```
    # redis.command("CLIENT", "ID") # => 42_i64
    # ```
    def command(*args : RESP::Arg)
      call(args)
    end

    # :ditto:
    def command(args : Indexable)
      call(args)
    end

    # Defines a typed command method. *params* are the fixed parameters in
    # wire order; with `splat: true` the last one becomes a splat. *cast* names
    # the `Cast` method applied to the reply. (`as` cannot be a macro
    # parameter name: it is a keyword.)
    #
    # ```
    # def_command get, "GET", key : String, cast: :string?
    # def_command del, "DEL", keys : String, cast: :int, splat: true
    # ```
    macro def_command(name, cmd, *params, cast, splat = false)
      {% if splat %}
        {% fixed = params[0...-1] %}
        {% last = params.last %}
      {% else %}
        {% fixed = params %}
      {% end %}
      def {{name.id}}({{fixed.splat}}{% if splat %}{% unless fixed.empty? %}, {% end %}*{{last.var}} : {{last.type}}{% end %})
        args = Array(::Redis::RESP::Arg).new({{fixed.size + 1}}{% if splat %} + {{last.var}}.size{% end %})
        args << {{cmd}}
        {% for p in fixed %}
          args << {{p.var}}
        {% end %}
        {% if splat %}
          {{last.var}}.each { |v| args << v }
        {% end %}
        typed_call(args) { |v| Cast.{{cast.id}}(v) }
      end
    end

    # Reply-shape conversions. Each accepts the RESP3 shape and the RESP2
    # shape of the same command and raises `ProtocolError` otherwise.
    # :nodoc:
    module Cast
      def self.value(v : Value) : Value
        v
      end

      def self.string(v : Value) : String
        v.as?(String) || unexpected(v, "string")
      end

      def self.string?(v : Value) : String?
        v.nil? ? nil : string(v)
      end

      def self.int(v : Value) : Int64
        v.as?(Int64) || unexpected(v, "integer")
      end

      def self.float(v : Value) : Float64
        case v
        when Float64 then v
        when Int64   then v.to_f64
        when String  then v.to_f64? || unexpected(v, "double")
        else              unexpected(v, "double")
        end
      end

      def self.float?(v : Value) : Float64?
        v.nil? ? nil : float(v)
      end

      def self.bool(v : Value) : Bool
        case v
        when Bool  then v
        when 0_i64 then false
        when 1_i64 then true
        else            unexpected(v, "boolean")
        end
      end

      def self.ok(v : Value) : Nil
        unexpected(v, "OK") unless v == "OK"
      end

      def self.strings(v : Value) : Array(String)
        elements(v, "array of strings").map { |e| string(e) }
      end

      def self.strings?(v : Value) : Array(String?)
        elements(v, "array of strings").map { |e| string?(e) }
      end

      def self.bools(v : Value) : Array(Bool)
        elements(v, "array of booleans").map { |e| bool(e) }
      end

      def self.floats?(v : Value) : Array(Float64?)
        elements(v, "array of doubles").map { |e| float?(e) }
      end

      def self.string_hash(v : Value) : Hash(String, String)
        case v
        when Hash
          v.each_with_object(Hash(String, String).new(initial_capacity: v.size)) do |(k, val), h|
            h[string(k)] = string(val)
          end
        when Array
          unexpected(v, "flat key-value array") if v.size.odd?
          h = Hash(String, String).new(initial_capacity: v.size // 2)
          i = 0
          while i < v.size
            h[string(v[i])] = string(v[i + 1])
            i += 2
          end
          h
        else
          unexpected(v, "map")
        end
      end

      def self.scored_pairs(v : Value) : Array({String, Float64})
        array = elements(v, "array of member-score pairs")
        if !array.empty? && array[0].is_a?(Array)
          array.map do |pair|
            p = pair.as?(Array) || unexpected(pair, "member-score pair")
            unexpected(pair, "member-score pair") unless p.size == 2
            {string(p[0]), float(p[1])}
          end
        else
          unexpected(v, "flat member-score array") if array.size.odd?
          result = Array({String, Float64}).new(array.size // 2)
          i = 0
          while i < array.size
            result << {string(array[i]), float(array[i + 1])}
            i += 2
          end
          result
        end
      end

      # Array, or Set for RESP3 set replies (SMEMBERS, SINTER, ...).
      # Public because hand-written commands use it.
      def self.elements(v : Value, expected : String) : Array(Value)
        case v
        when Array then v
        when Set
          # Not `v.to_a`: `Set(Value)#to_a` goes through `Hash(Value,
          # Nil)#keys`, whose declared `Array(K)` return type the compiler
          # cannot unify with `Value` for this self-referential alias.
          array = Array(Value).new(v.size)
          v.each { |e| array << e }
          array
        else
          unexpected(v, expected)
        end
      end

      def self.unexpected(v : Value, expected : String) : NoReturn
        raise ProtocolError.new("unexpected reply: expected #{expected}, got #{v.inspect}")
      end

      # `{cursor, elements}` as returned by the SCAN family.
      def self.scan_page(v : Value) : {String, Array(String)}
        page = elements(v, "scan page")
        unexpected(v, "scan page") unless page.size == 2
        {string(page[0]), strings(page[1])}
      end
    end
  end
end

require "./commands/*"
