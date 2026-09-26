#!/bin/sh
# Checks that invalid layouts fail with the expected macro messages.
# Usage: .remember/harness-2026-09-17/format/compile_errors.sh (from repo root)
set -u
dir=$(mktemp -d)
fail=0
check() {
  name=$1; expected=$2; body=$3
  printf 'require "binary"\nstruct T\n  include Binary::Format\n%s\nend\nT\n' "$body" > "$dir/$name.cr"
  out=$(bin/crystal build --no-codegen "$dir/$name.cr" 2>&1)
  if printf '%s' "$out" | grep -q "$expected"; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected'"; printf '%s\n' "$out" | grep -v "ld64.lld\|Using compiled" | head -5; fail=1
  fi
}
check unknown_option "option \`foo:\` is not valid" '  field a : UInt8, foo: 1'
check string_mode "needs exactly one of" '  field s : String'
# NOTE (adjustment): brief's original body was `field b : Bytes, cstring: true`,
# but `cstring:` is not in the allowed option list for a Bytes field (only
# String), so that body raises "option `cstring:` is not valid ..." instead
# of the mode-check message. Dropped cstring: true so this exercises the
# modes==0 path, same as string_mode above.
check bytes_mode "needs exactly one of" '  field b : Bytes'
check if_not_nilable "must be declared nilable" '  field a : UInt8, if: ->{ true }'
check nilable_without_if "needs an \`if:\` condition" '  field a : UInt8?'
check size_of_not_int "needs an integer type" '  field a : String, cstring: true, size_of: :rest'
check derived_default "cannot have a default value" '  field n : UInt8 = 1
  field s : String, length: :n'
check two_size_of "only one field may have" '  field a : UInt32, size_of: :rest
  field b : UInt32, size_of: :rest'
check bits_boundary "must end on a byte boundary" '  field a : UInt8, bits: 3'
check bits_too_wide "is wider than UInt8" '  field a : UInt8, bits: 9
  field b : UInt8, bits: 7'
check bits_over_64 "may not exceed 64 bits" '  field a : UInt64, bits: 64
  field b : UInt8, bits: 8'
check varint_float "needs an integer or enum type" '  field a : Float32, varint: true'
# NOTE (adjustment, per Fact 1): actual macro message is "needs an explicit
# type suffix other than _i32", not "needs a type suffix".
check magic_no_suffix "needs an explicit type suffix other than _i32" '  magic 0x1234'
check align_variable "needs every preceding entry" '  field s : String, cstring: true
  align 4'
check nested_order "must be defined before" '  field p : Later
end
struct Later
  include Binary::Format
  field a : UInt8'
check length_unknown "names an unknown field" '  field s : String, length: :nope'
check length_after "declared before it" '  field s : String, length: :n
  field n : UInt8'
# NOTE (new check, per Fact 2): `if:` cannot be combined with `value:` or
# `size_of:`.
check if_with_value "cannot be combined with \`value:\` or \`size_of:\`" '  field a : UInt8?, if: ->{ true }, value: ->{ 1 }'
rm -rf "$dir"
exit $fail
