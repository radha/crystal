require "./postgres/error"
require "./postgres/config"
require "./postgres/interval"
require "./postgres/connection"
require "./postgres/client"
require "./postgres/listener"
require "./postgres/copy"
require "./postgres/pipeline"

# A pure-Crystal PostgreSQL client speaking the frontend/backend protocol
# 3.0 over TCP, Unix sockets or TLS.
#
# ```
# require "postgres"
#
# struct User
#   include Postgres::Serializable
#   getter id : Int64
#   getter name : String
#   @[Postgres::Field(key: "email_address")]
#   getter email : String?
# end
#
# db = Postgres::Client.new("postgres://app:secret@localhost/app_dev")
# db.exec("insert into users (name, email_address) values ($1, $2)", "ana", nil)
# db.query_all("select * from users where id > $1", 0, as: User) # => [User(...)]
# db.query_one("select count(*) from users", as: Int64)          # => 1
# db.transaction do |tx|
#   tx.exec("update users set name = $1 where id = $2", "ana b", 1)
# end
# db.close
# ```
#
# `Client` is fiber-safe and pools connections (see `Pool`); `Connection` is
# a single session. Settings come from the URL (`postgres://` or
# `postgresql://`, see `Config.parse`), keyword arguments, and the `PGHOST`,
# `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`,
# `PGSSLROOTCERT`, `PGAPPNAME` and `PGCONNECT_TIMEOUT` environment variables.
# `sslmode` defaults to `prefer`. Authentication: trust, cleartext, MD5 and
# SCRAM-SHA-256 (without channel binding or SASLprep).
#
# ### Types
#
# Results decode by column type into the requested Crystal type:
#
# | Crystal | PostgreSQL |
# |---|---|
# | `Bool` | bool |
# | `Int16`, `Int32`, `Int64` | int2; int2, int4; int2, int4, int8 |
# | `UInt32` | oid |
# | `Float32`, `Float64` | float4; float4, float8 |
# | `BigDecimal` | numeric, int2/4/8 |
# | `String` | text, varchar, bpchar, name, char, json, jsonb, xml, the canonical text of inet/cidr/macaddr/timetz/bit/ranges, and any type without a binary decoder (as the server's text form) |
# | `Bytes` | bytea |
# | `UUID` | uuid |
# | `Time` | timestamptz, timestamp (as UTC), date (UTC midnight) |
# | `Time::Span` | time, interval without months |
# | `Postgres::Interval` | interval |
# | `JSON::Any` | json, jsonb |
# | `Postgres::Inet`, `Socket::IPAddress` | inet, cidr |
# | `Postgres::MacAddress` | macaddr, macaddr8 |
# | `Postgres::TimeTz` | timetz |
# | `BitArray` | bit, varbit |
# | `Int64` | money (minor units, e.g. cents) |
# | `Postgres::Range(T)` | int4range, int8range, numrange, tsrange, tstzrange, daterange (a Crystal `Range` works as a parameter) |
# | `Hash(String, String?)` | hstore |
# | an `enum` | a PostgreSQL enum or text column (by label), an integer column (by value) |
# | `Array(T)`, `Array(T?)` | one-dimensional arrays of the types above (`int4[]`, `text[]`, ...) |
#
# A nilable type reads SQL NULL as `nil`. Parameters are encoded for the
# type the server inferred for them; a `String` works for any type (it is
# sent as text for the server to parse), so enums, `inet` or array
# literals like `"{1,2}"` can be passed as strings. An `Array` is sent in
# binary for the array types above and as a quoted text literal otherwise
# (e.g. `Array(String)` for an `inet[]` parameter), so `where id = any($1)`
# takes a plain Crystal array.
#
# `Client#listener` (or `Listener.new`) opens a `Listener` for
# `LISTEN`/`NOTIFY` on a connection of its own; `Client#notify` sends one.
#
# `Connection#copy_from` and `#copy_to` stream `COPY` in any format;
# `Connection#copy_rows` bulk-inserts typed rows with binary `COPY`.
#
# `Connection#pipeline` (and `Client#pipeline`) sends many queries in two
# round trips and returns a typed `Future` per query; each query succeeds
# or fails on its own. A query that exceeds `read_timeout` is cancelled
# server-side and raises `IO::TimeoutError`, leaving the session usable.
#
# Not supported yet: multi-dimensional arrays, SCRAM channel binding.
module Postgres
end
