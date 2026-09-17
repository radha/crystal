# `Binary::Format` design (Tier 1d) with bit IO (Tier 1b)

Date: 2026-09-17. Status: approved in brainstorm, ready for planning.

## Goal

A declarative, macro-generated layout for binary structs, in the shape of
`JSON::Serializable` but with a `field` DSL, so that Postgres wire messages,
the RPC frame header, and file headers (PNG, ELF) are declared once and get
`read`, `write`, `from_slice`, `to_slice`, `byte_size` for free. Fixed
layouts additionally get a compile-time `SIZE` and a pointer-offset decoder,
which seeds the later zero-copy RPC path.

Ships together with `Binary::BitReader` / `Binary::BitWriter` (Tier 1b).

Decisions taken in the brainstorm and not to be reopened:

- `field` DSL (bindata/binrw style), not annotations on ivars.
- Protocol-complete option set plus packed bit fields, in one slice.
- Length and count fields referenced by another field are derived on write.
- Implementation via annotated marker defs collected in `macro finished`
  (verified feasible in a spike: order is preserved and
  `@type.methods.size` is a usable unique counter for unnamed entries).

## 1. Declaration surface

```crystal
require "binary"

struct Startup
  include Binary::Format
  field length  : Int32, size_of: :rest, including_self: true
  field version : Int32 = 196608
  field params  : Array(String), cstring: true, until: :eof
end

struct PngHeader
  include Binary::Format
  magic Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  field width  : UInt32
  field height : UInt32
  field depth  : UInt8
  pad 3
end
```

### Type-level directives

- `endian :big | :little | :native`: default for multi-byte integers, floats
  and enums. Defaults to `:big` (network order), the same default as
  `Binary::Frame`'s `:u32_be`.
- `bit_order :msb | :lsb`: bit packing order for `bits:` runs. Default `:msb`.

### Layout entries (wire order = declaration order)

- `field name : Type` / `field name : Type = default`. Defines the ivar, a
  getter, and a setter unless the field is derived.
- `pad n`: skip `n` bytes on read, write `n` zero bytes.
- `align n`: pad to the next multiple of `n` bytes counted from the start of
  the record.
- `magic value`: `Bytes`, `String`, or an integer literal with an explicit
  type suffix (`0x89504E47_u32`, written with the type's endian). Read
  asserts equality and raises `Binary::Format::MagicError`; write emits it.
  No ivar.

### Field types

`Int8..Int128`, `UInt8..UInt128`, `Float32`, `Float64`, `Bool` (one byte,
nonzero reads as true, writes 1/0), enums with an integer base type,
`String`, `Bytes`, `StaticArray(T, N)` (inline, element type any supported
type), `Array(T)`, any type that includes `Binary::Format`, and `T?` only in
combination with `if:`.

### Field options

| option | applies to | meaning |
|---|---|---|
| `endian:` | ints, floats, enums | per-field override |
| `varint: true` | ints, enums | unsigned LEB128 via `Binary::Varint`; zigzag when the type is signed |
| `bits: n` | ints, Bool, enums | packed bit field (section 3) |
| `length: :other \| Int \| ->{ expr }` | String, Bytes | byte length. Symbol form names an earlier integer field, which becomes derived |
| `cstring: true` | String, Array(String) | NUL-terminated, no length. On an array, applies per element |
| `count: :other \| Int \| ->{ expr }` | Array | element count. Symbol form derives the named field |
| `until: :eof` | String, Bytes, Array | consume the rest of the bounding stream |
| `sentinel: value` | Array | read elements until one equals `value`, drop it; write it after the elements |
| `size_of: :rest` | ints | field holds the byte length of everything after it; bounds the rest of the read with `IO::Sized`; derived on write. `including_self: true` adds the field's own width (Postgres) |
| `value: ->{ expr }` | any | derived: computed on write, excluded from the constructor, populated on read |
| `if: ->{ expr }` | any `T?` | present only when the expression is true, evaluated against earlier fields |
| `max: n` | String, Bytes, Array | allocation guard for length/count prefixes; raises `Binary::Format::SizeError` |

Exactly one of `length:`, `cstring:`, `until:` is required on `String`.
`Bytes` requires `length:` or `until:`. `Array` requires `count:`, `until:`
or `sentinel:`. Element options (`endian:`, `varint:`, `cstring:`,
`length:` for `Array(String)`/`Array(Bytes)`) apply to each element.

`->{ expr }` bodies reference earlier fields by bare name. This works on both
read and write (section 2). Only earlier fields may be referenced; a
reference to a later field fails to compile on the read path because the
local does not exist yet.

The trailing NUL of a Postgres parameter list reads back as an empty final
string, which the Postgres client drops. The DSL deliberately has no
peek-for-terminator mode.

## 2. Generated API and mechanics

Generated on the including type:

- `initialize(*, a, b = default, ...)`: keyword constructor over every
  non-derived field, in layout order. `if:` fields default to `nil`.
- `self.read(io : IO) : self`. Truncation raises `IO::EOFError`.
- `self.from_slice(bytes : Bytes) : self` and
  `self.from_slice(bytes : Bytes, offset : Int) : {self, Int32}` returning
  the value and the number of bytes consumed. Non-fixed layouts read through
  `IO::Memory` over the slice; fixed layouts use the pointer path (section 4).
- `write(io : IO) : Nil`.
- `to_slice : Bytes`: allocates exactly `byte_size` bytes.
- `byte_size : Int32`: sum of per-field sizes, computed without writing.
- `IO#read_bytes` / `IO#write_bytes` are not overloaded; `T.read(io)` and
  `value.write(io)` are the entry points, mirroring `Binary::Frame`.

### Read

`read` builds the value through `initialize(*, __binary_io io : IO)`, the
same route `JSON::Serializable` uses, so it works for `struct` and `class`.
Inside, every field is read in layout order into a local variable named
exactly like the field. Expression bodies from `if:`, `length:`, `count:`,
`value:` are inlined as expressions, so a bare `flags` binds to the local on
read and to the getter on write. Ivars are assigned at the end from the
locals. Derived fields are read like any other field (their value is what
the stream says) and then also checked where cheap: a `count:`-derived field
is what drives the array read, so no separate check is needed.

A `size_of: :rest` field wraps the source in `IO::Sized.new(io, n, sync_close: false)`
for the remaining fields (`n` minus the field width when
`including_self: true`). `until: :eof` reads until `io.peek` is empty or
`nil`. `IO::Memory`, `IO::Sized` and every `IO::Buffered` support `peek`; a
source whose `peek` returns `nil` raises `Binary::Format::Error` naming the
field.

`if:` false leaves the field `nil`. `sentinel:` compares with `==`.

### Write

Fields are emitted in order. Derived fields evaluate first: `count: :n`
writes `items.size`, `length: :n` writes `str.bytesize`, `size_of: :rest`
writes the summed `byte_size` of the following fields plus its own width
when `including_self`. Primitives go through `IO::ByteFormat`, varints
through `Binary::Varint`, nested types through their own `write`. `String`
and `Bytes` are written raw; `cstring` appends the NUL and raises
`Binary::Format::Error` if the string contains a NUL. `if:` fields that are
`nil` while the condition is true raise `Binary::Format::Error`; fields that
are non-nil while the condition is false are skipped silently.

### Compile-time checks

All raise inside the macro with the type and field name: unknown option;
option not valid for the field type; missing required option on
`String`/`Bytes`/`Array`; `if:` on a non-nilable type; `size_of:` on a
non-integer; a derived field with a default value; more than one
`size_of: :rest`; a `bits:` run that does not end on a byte boundary or
exceeds 64 bits; `bits:` wider than the field type; `varint:` on a
non-integer; `magic` with an integer literal lacking a type suffix.

## 3. Bit fields and bit IO

### Packed fields

Consecutive `bits: n` fields form a run. The run total must be a multiple
of 8 and at most 64, checked at compile time. Read loads the run's bytes
into a `UInt64` accumulator and extracts each field with shift and mask in
`bit_order`:

- `:msb` (default): the first declared field occupies the most significant
  bits of the first byte, as IP/TCP headers and most codecs are drawn.
- `:lsb`: the first field occupies the least significant bits of the first
  byte (deflate style).

Write packs the same way and emits the bytes. `Bool` with `bits: 1` reads as
`!= 0`; an enum takes its base-type value. A value wider than `n` bits
raises `Binary::Format::Error` on write. No runtime `BitReader` is involved,
so a packed header costs the same as an integer read.

### `Binary::BitReader` and `Binary::BitWriter`

- `Binary::BitOrder` enum `Msb | Lsb`, shared with `bit_order`.
- `BitReader.new(bytes : Bytes, order : BitOrder = :msb)` and
  `BitReader.new(io : IO, order : BitOrder = :msb)`.
  `read_bits(n : Int) : UInt64` for `n` in `0..64`, `read_bit : Bool`,
  `read_bits?(n) : UInt64?` returning `nil` when fewer than `n` bits remain,
  `align! : Nil` to the next byte boundary, `bit_position : Int64`,
  `eof? : Bool`. Reading past the end raises `IO::EOFError`.
- `BitWriter.new(io : IO, order : BitOrder = :msb)` and `BitWriter.new(order)`
  writing to an internal `IO::Memory` with `to_slice`.
  `write_bits(value : UInt64, n : Int) : Nil` (value must fit in `n` bits or
  raises `ArgumentError`), `write_bit(Bool)`, `align! : Nil` pads with zero
  bits, `flush : Nil` emits the partial byte zero-padded, `close` flushes.
  `bit_position : Int64`.
- 64-bit accumulator with a bit count. The slice-backed reader refills 8
  bytes at a time through `IO::ByteFormat` when at least 8 bytes remain,
  byte-wise at the tail. The IO-backed reader refills one byte at a time.

## 4. Fixed layouts, errors, limits

### Fixed layouts

A format is fixed when every entry has a compile-time width: integers,
floats, `Bool`, enums, `StaticArray` of fixed types, nested fixed formats,
`pad`, `align`, `magic`, `bits:` runs. Not fixed: `varint`, `String`,
`Bytes`, `Array`, `if:`, `size_of`, any nested non-fixed format.

For fixed formats the macro additionally generates:

- `SIZE : Int32` and `self.fixed_size? : Bool` (`true`; non-fixed formats
  get `false` and no `SIZE`).
- `from_slice(bytes)` checks `bytes.size >= SIZE` (raises `IO::EOFError`
  otherwise, same as the IO path) and decodes each field at its computed
  offset via `IO::ByteFormat.decode(T, bytes + offset)`: a load plus a byte
  swap when the endian differs from the host.
- `write_to(bytes : Bytes) : Int32` encoding by offset, and `to_slice` built
  on it.
- `write(io)` encodes into a stack `StaticArray(UInt8, SIZE)` and issues one
  `io.write`, so a 12-byte RPC header is one syscall on an unbuffered socket.

Alignment is wire alignment only; nothing about the Crystal struct's memory
layout is assumed or exposed.

### Errors

All under `Binary::Error`:

- `Binary::Format::Error`: base; also raised directly for invalid values on
  write (NUL in a cstring, value too wide for `bits:`, negative derived
  length, `nil` in an `if:` field whose condition is true) and for
  unsupported IOs (`until: :eof` without `peek`).
- `Binary::Format::MagicError < Format::Error`: message shows expected and
  actual bytes.
- `Binary::Format::SizeError < Format::Error`: a length or count prefix
  exceeds `max:`, or is negative for signed prefixes.
- Truncated input raises `IO::EOFError`, consistent with `Varint` and `Frame`.

### Limits

`max:` defaults to `Binary::Frame::DEFAULT_MAX_SIZE` (16 MiB) for byte
lengths and 16 Mi elements for counts. Count-prefixed arrays are presized
only up to 64 Ki elements so a hostile count cannot force a large allocation
before any element is read.

## 5. Files, specs, benchmarks

### Files

- `src/binary/bit_order.cr`: `BitOrder`.
- `src/binary/bit_io.cr`: `BitReader`, `BitWriter`.
- `src/binary/format.cr`: `Format` module, error classes, DSL macros
  (`endian`, `bit_order`, `field`, `pad`, `align`, `magic`), and the
  `finished` generator, split into private helper macros per concern
  (`__binary_gen_read`, `__binary_gen_write`, `__binary_gen_size`,
  `__binary_gen_fixed`).
- `src/binary.cr` requires the three new files; `require "binary"` remains
  the single entry point. Never in the prelude.
- `spec/std/binary/bit_io_spec.cr`, `spec/std/binary/format_spec.cr`.

### Specs

- Known-answer byte dumps: PNG signature + IHDR, ELF64 header, Postgres
  StartupMessage, Query, RowDescription, DataRow, and the RPC frame header
  `{type : UInt8, flags : UInt8, stream_id : UInt32, length : UInt32}`.
  Each asserts `to_slice` equals the dump and `read`/`from_slice` recover
  the value.
- Round-trip: every option in the table alone, then combined, through
  `IO::Memory` and `from_slice`. Random-instance round-trip loop for the
  fixed and the Postgres fixtures.
- Error paths: truncation, magic mismatch, `max:` exceeded, NUL in cstring,
  `bits:` overflow on write, `until: :eof` on a non-peekable IO, `nil` in a
  required `if:` field.
- Fixed path: `SIZE`, `fixed_size?`, `from_slice` with offset, `write_to`,
  single-write behaviour observable through a counting IO.
- Bit IO: MSB and LSB byte-exact vectors, `BitWriter` output reads back with
  `BitReader` for random widths, `align!`, `read_bits?` and EOF behaviour,
  the 8-byte refill boundary.
- Compile-time error messages are exercised by a script in the bench
  harness directory, not in the spec suite.

### Benchmarks

In `.remember/harness-2026-09-17/` (gitignored): read and write of the
12-byte fixed header and of a 10-column Postgres DataRow, against Rust
`binrw` and a hand-written Go `encoding/binary` loop. Target: fixed header
within 10% of Rust, variable path within 30%. `make format` and the full
`std_spec` run before each commit.

## Out of scope for this slice

Inheritance between formats, tuples as field types, `Char`, peek-based
terminators, `bits:` runs over 64 bits, an `IO#read_bytes(T)` overload,
runtime layout introspection, and the Tier 2 serializer.
