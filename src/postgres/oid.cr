module Postgres
  # :nodoc:
  #
  # Type OIDs of the built-in types the codec knows (`pg_type.oid`).
  module OID
    BOOL         =   16_u32
    BYTEA        =   17_u32
    CHAR         =   18_u32
    NAME         =   19_u32
    INT8         =   20_u32
    INT2         =   21_u32
    INT4         =   23_u32
    TEXT         =   25_u32
    OID          =   26_u32
    JSON         =  114_u32
    FLOAT4       =  700_u32
    FLOAT8       =  701_u32
    UNKNOWN      =  705_u32
    BPCHAR       = 1042_u32
    VARCHAR      = 1043_u32
    DATE         = 1082_u32
    TIME         = 1083_u32
    TIMESTAMP    = 1114_u32
    TIMESTAMPTZ  = 1184_u32
    INTERVAL     = 1186_u32
    NUMERIC      = 1700_u32
    UUID         = 2950_u32
    JSONB        = 3802_u32
    RECORD       = 2249_u32
    RECORD_ARRAY = 2287_u32
    XML          =  142_u32
    CIDR         =  650_u32
    MONEY        =  790_u32
    MACADDR8     =  774_u32
    MACADDR      =  829_u32
    INET         =  869_u32
    TIMETZ       = 1266_u32
    BIT          = 1560_u32
    VARBIT       = 1562_u32

    # :nodoc:
    # Range types and their element types.
    RANGE_ELEMENTS = {
      3904_u32 => INT4, 3926_u32 => INT8, 3906_u32 => NUMERIC,
      3908_u32 => TIMESTAMP, 3910_u32 => TIMESTAMPTZ, 3912_u32 => DATE,
    }

    # The element type of range type *oid*, or nil.
    def self.range_element(oid : UInt32) : UInt32?
      RANGE_ELEMENTS[oid]?
    end

    # :nodoc:
    # One-dimensional array types and their element types.
    ARRAY_ELEMENTS = {
      1000_u32 => BOOL, 1001_u32 => BYTEA, 1002_u32 => CHAR, 1003_u32 => NAME, 1016_u32 => INT8,
      1005_u32 => INT2, 1007_u32 => INT4, 1009_u32 => TEXT, 1028_u32 => OID, 199_u32 => JSON,
      1021_u32 => FLOAT4, 1022_u32 => FLOAT8, 1014_u32 => BPCHAR, 1015_u32 => VARCHAR,
      1182_u32 => DATE, 1183_u32 => TIME, 1115_u32 => TIMESTAMP, 1185_u32 => TIMESTAMPTZ,
      1187_u32 => INTERVAL, 1231_u32 => NUMERIC, 2951_u32 => UUID, 3807_u32 => JSONB,
      143_u32 => XML, 651_u32 => CIDR, 791_u32 => MONEY, 775_u32 => MACADDR8, 1040_u32 => MACADDR,
      1041_u32 => INET, 1270_u32 => TIMETZ, 1561_u32 => BIT, 1563_u32 => VARBIT,
      3905_u32 => 3904_u32, 3927_u32 => 3926_u32, 3907_u32 => 3906_u32, 3909_u32 => 3908_u32,
      3911_u32 => 3910_u32, 3913_u32 => 3912_u32,
      2287_u32 => RECORD,
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
           BPCHAR, VARCHAR, DATE, TIME, TIMESTAMP, TIMESTAMPTZ, INTERVAL, NUMERIC, UUID, JSONB,
           XML, CIDR, MONEY, MACADDR8, MACADDR, INET, TIMETZ, BIT, VARBIT, RECORD
        true
      else
        ARRAY_ELEMENTS.has_key?(oid) || RANGE_ELEMENTS.has_key?(oid)
      end
    end

    # Whether *oid* is a string type whose binary form is its UTF-8 text.
    def self.text?(oid : UInt32) : Bool
      case oid
      when TEXT, VARCHAR, BPCHAR, NAME, CHAR, UNKNOWN, XML then true
      else                                                      false
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
      when RECORD      then "record"
      when XML         then "xml"
      when CIDR        then "cidr"
      when MONEY       then "money"
      when MACADDR8    then "macaddr8"
      when MACADDR     then "macaddr"
      when INET        then "inet"
      when TIMETZ      then "timetz"
      when BIT         then "bit"
      when VARBIT      then "varbit"
      when 3904_u32    then "int4range"
      when 3926_u32    then "int8range"
      when 3906_u32    then "numrange"
      when 3908_u32    then "tsrange"
      when 3910_u32    then "tstzrange"
      when 3912_u32    then "daterange"
      else                  (elem = element(oid)) ? "#{name(elem)}[]" : "oid #{oid}"
      end
    end
  end
end
