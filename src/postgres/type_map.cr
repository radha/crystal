require "./oid"

module Postgres
  # :nodoc:
  #
  # What one connection learned about type OIDs the codec does not know
  # (they are per database): domains resolve to their base type,
  # composites to `record`, arrays of those to the matching array type.
  # Filled lazily by `Connection` with one `pg_type` query per batch of
  # new OIDs.
  class TypeMap
    # declared OID → OID the codec decodes a column of that type as
    @columns = {} of UInt32 => UInt32
    # declared OID → OID the codec encodes a parameter of that type as
    @params = {} of UInt32 => UInt32
    @seen = Set(UInt32).new
    # domain OID → its base type's array type (for arrays of the domain)
    @base_arrays = {} of UInt32 => UInt32

    def resolve_column(oid : UInt32) : UInt32
      @columns[oid]? || oid
    end

    def resolve_param(oid : UInt32) : UInt32
      @params[oid]? || oid
    end

    # The OIDs among *oids* worth asking the server about.
    def unknown(oids : Enumerable(UInt32)) : Array(UInt32)
      oids.reject { |oid| oid == 0 || OID.binary?(oid) || OID.text?(oid) || @seen.includes?(oid) }.uniq
    end

    # Records what `pg_type` says about *oid*: its kind, and (for domains)
    # the ultimate base type, (for arrays) the element\'s resolution.
    def learn(oid : UInt32, kind : String, base : UInt32, element : UInt32, base_array : UInt32) : Nil
      @seen << oid
      case kind
      when "d" # domain: behave as the base type
        @columns[oid] = base
        @params[oid] = base
        @base_arrays[oid] = base_array
      when "c" # composite: binary `record` on the way out; text in
        @columns[oid] = OID::RECORD
      else
        if element != 0
          resolved = resolve_column(element)
          if resolved == OID::RECORD
            @columns[oid] = OID::RECORD_ARRAY
          elsif (array = @base_arrays[element]?) && array != 0
            # an array of a domain: decode as the base type's array (the
            # header names the domain, which resolves element-wise)
            @columns[oid] = array
          end
        end
      end
    end

    # The SQL `Connection` runs for the OIDs in `$1`: per OID its kind,
    # element type, for domains the base type at the end of the chain and
    # that base's array type, and for composites their field types.
    INTROSPECT = <<-SQL
      with recursive chain(root, oid) as (
        select t.oid, t.oid from pg_type t where t.oid = any($1::oid[])
        union all
        select c.root, t.typbasetype from chain c join pg_type t on t.oid = c.oid where t.typtype = 'd'
      )
      select r.oid, r.typtype::text, b.oid, r.typelem, b.typarray,
        coalesce(array(select a.atttypid from pg_attribute a
                       where a.attrelid = r.typrelid and a.attnum > 0 and not a.attisdropped
                       order by a.attnum), '{}')
      from chain c
      join pg_type r on r.oid = c.root
      join pg_type b on b.oid = c.oid
      where b.typtype <> 'd'
      SQL
  end
end
