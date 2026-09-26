module Postgres
  # :nodoc:
  #
  # Type OIDs of the built-in types the codec knows (`pg_type.oid`).
  module OID
    BOOL        =   16_u32
    BYTEA       =   17_u32
    CHAR        =   18_u32
    NAME        =   19_u32
    INT8        =   20_u32
    INT2        =   21_u32
    INT4        =   23_u32
    TEXT        =   25_u32
    OID         =   26_u32
    JSON        =  114_u32
    FLOAT4      =  700_u32
    FLOAT8      =  701_u32
    UNKNOWN     =  705_u32
    BPCHAR      = 1042_u32
    VARCHAR     = 1043_u32
    DATE        = 1082_u32
    TIME        = 1083_u32
    TIMESTAMP   = 1114_u32
    TIMESTAMPTZ = 1184_u32
    INTERVAL    = 1186_u32
    NUMERIC     = 1700_u32
    UUID        = 2950_u32
    JSONB       = 3802_u32

    # :nodoc:
    # One-dimensional array types and their element types.
    ARRAY_ELEMENTS = {
      1000_u32 => BOOL, 1001_u32 => BYTEA, 1002_u32 => CHAR, 1003_u32 => NAME, 1016_u32 => INT8,
      1005_u32 => INT2, 1007_u32 => INT4, 1009_u32 => TEXT, 1028_u32 => OID, 199_u32 => JSON,
      1021_u32 => FLOAT4, 1022_u32 => FLOAT8, 1014_u32 => BPCHAR, 1015_u32 => VARCHAR,
      1182_u32 => DATE, 1183_u32 => TIME, 1115_u32 => TIMESTAMP, 1185_u32 => TIMESTAMPTZ,
      1187_u32 => INTERVAL, 1231_u32 => NUMERIC, 2951_u32 => UUID, 3807_u32 => JSONB,
    }

    # The element type of array type *oid*, or nil if *oid* is not an
    # array type the codec knows.
    def self.element(oid : UInt32) : UInt32?
      ARRAY_ELEMENTS[oid]?
    end

    # Whether the codec decodes *oid* in binary; everything else is
    # requested in text format.
    def self.binary?(oid : UInt32) : Bool
      case oid
      when BOOL, BYTEA, CHAR, NAME, INT8, INT2, INT4, TEXT, OID, JSON, FLOAT4, FLOAT8, UNKNOWN,
           BPCHAR, VARCHAR, DATE, TIME, TIMESTAMP, TIMESTAMPTZ, INTERVAL, NUMERIC, UUID, JSONB
        true
      else
        ARRAY_ELEMENTS.has_key?(oid)
      end
    end

    # Whether *oid* is a string type whose binary form is its UTF-8 text.
    def self.text?(oid : UInt32) : Bool
      case oid
      when TEXT, VARCHAR, BPCHAR, NAME, CHAR, UNKNOWN then true
      else                                                 false
      end
    end

    # The type name for error messages.
    def self.name(oid : UInt32) : String
      case oid
      when BOOL        then "bool"
      when BYTEA       then "bytea"
      when CHAR        then "char"
      when NAME        then "name"
      when INT8        then "int8"
      when INT2        then "int2"
      when INT4        then "int4"
      when TEXT        then "text"
      when OID         then "oid"
      when JSON        then "json"
      when FLOAT4      then "float4"
      when FLOAT8      then "float8"
      when UNKNOWN     then "unknown"
      when BPCHAR      then "bpchar"
      when VARCHAR     then "varchar"
      when DATE        then "date"
      when TIME        then "time"
      when TIMESTAMP   then "timestamp"
      when TIMESTAMPTZ then "timestamptz"
      when INTERVAL    then "interval"
      when NUMERIC     then "numeric"
      when UUID        then "uuid"
      when JSONB       then "jsonb"
      else                  (elem = element(oid)) ? "#{name(elem)}[]" : "oid #{oid}"
      end
    end
  end
end
