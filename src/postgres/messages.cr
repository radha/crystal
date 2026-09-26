require "binary"

module Postgres
  # :nodoc:
  #
  # `Binary::Format` layouts of the protocol 3.0 messages with a declarative
  # shape. Frontend messages carry their type byte and self-inclusive
  # length; backend layouts describe the body only, since the reader
  # dispatches on the type byte first. `Bind` and `DataRow`, the hot path,
  # are handled by hand in `Connection` and `RowReader`.
  module Messages
    PROTOCOL_VERSION    =    196_608 # 3.0
    SSL_REQUEST_CODE    = 80_877_103
    CANCEL_REQUEST_CODE = 80_877_102

    struct Startup
      include Binary::Format
      field length : Int32, size_of: :rest, including_self: true
      field protocol : Int32 = PROTOCOL_VERSION
      field params : Array(String), cstring: true, sentinel: ""
    end

    struct SSLRequest
      include Binary::Format
      field length : Int32 = 8
      field code : Int32 = SSL_REQUEST_CODE
    end

    struct Query
      include Binary::Format
      magic "Q"
      field length : Int32, size_of: :rest, including_self: true
      field query : String, cstring: true
    end

    struct Parse
      include Binary::Format
      magic "P"
      field length : Int32, size_of: :rest, including_self: true
      field name : String, cstring: true
      field query : String, cstring: true
      field count : Int16
      field oids : Array(UInt32), count: :count
    end

    # `Describe` (`'D'`) and `Close` (`'C'`) share this body: kind `'S'`
    # (statement) or `'P'` (portal) and a name.
    struct Describe
      include Binary::Format
      magic "D"
      field length : Int32, size_of: :rest, including_self: true
      field kind : UInt8
      field name : String, cstring: true
    end

    struct Close
      include Binary::Format
      magic "C"
      field length : Int32, size_of: :rest, including_self: true
      field kind : UInt8
      field name : String, cstring: true
    end

    struct Execute
      include Binary::Format
      magic "E"
      field length : Int32, size_of: :rest, including_self: true
      field portal : String, cstring: true
      field max_rows : Int32 = 0
    end

    struct Password
      include Binary::Format
      magic "p"
      field length : Int32, size_of: :rest, including_self: true
      field password : String, cstring: true
    end

    struct SASLInitialResponse
      include Binary::Format
      magic "p"
      field length : Int32, size_of: :rest, including_self: true
      field mechanism : String, cstring: true
      field data_length : Int32
      field data : String, length: :data_length
    end

    struct SASLResponse
      include Binary::Format
      magic "p"
      field length : Int32, size_of: :rest, including_self: true
      field data : String, until: :eof
    end

    # Body-less frontend messages: `Sync` (`S`), `Flush` (`H`), `Terminate` (`X`).
    SYNC      = Bytes['S'.ord, 0, 0, 0, 4]
    FLUSH     = Bytes['H'.ord, 0, 0, 0, 4]
    TERMINATE = Bytes['X'.ord, 0, 0, 0, 4]

    struct CancelRequest
      include Binary::Format
      field length : Int32 = 16
      field code : Int32 = CANCEL_REQUEST_CODE
      field pid : Int32
      field secret : Int32
    end

    struct BackendKeyData
      include Binary::Format
      field pid : Int32
      field secret : Int32
    end

    struct ParameterStatus
      include Binary::Format
      field name : String, cstring: true
      field value : String, cstring: true
    end

    struct ParameterDescription
      include Binary::Format
      field count : Int16
      field oids : Array(UInt32), count: :count, max: 65535
    end

    struct ColumnDescription
      include Binary::Format
      field name : String, cstring: true
      field table_oid : UInt32
      field column : Int16
      field type_oid : UInt32
      field type_size : Int16
      field type_modifier : Int32
      field format : Int16
    end

    struct RowDescription
      include Binary::Format
      field count : Int16
      field columns : Array(ColumnDescription), count: :count, max: 1664
    end

    struct NotificationResponse
      include Binary::Format
      field pid : Int32
      field channel : String, cstring: true
      field payload : String, cstring: true
    end

    struct CommandComplete
      include Binary::Format
      field tag : String, cstring: true
    end
  end
end
