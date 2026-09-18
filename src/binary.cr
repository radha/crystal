# Format-agnostic building blocks for binary protocols and file formats:
# variable-length integers (`Binary::Varint`, `Binary::Zigzag`),
# length-prefixed framing (`Binary::Frame`), bit-level IO
# (`Binary::BitReader`, `Binary::BitWriter`) and declarative struct layouts
# (`Binary::Format`).
#
# NOTE: To use `Binary`, you must explicitly import it with `require "binary"`
module Binary
  # Base class of every error raised by the `Binary` module for malformed
  # input. Truncated input read from an `IO` raises `IO::EOFError` instead.
  class Error < Exception
  end
end

require "./binary/varint"
require "./binary/frame"
require "./binary/bit_order"
require "./binary/bit_io"
require "./binary/format"
