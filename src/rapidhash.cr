# `Rapidhash` is a fast, portable, non-cryptographic 64-bit hash: a port of
# [rapidhash](https://github.com/Nicoshev/rapidhash) V3 by Nicolas De
# Carli, the successor of wyhash.
#
# Unlike `Object#hash`, whose seed changes on every run of the program, the
# result depends only on the input bytes and the explicit *seed*. That makes
# it suitable for data that outlives a process or crosses a machine
# boundary: persisted sketches (`BloomFilter`, `HyperLogLog`,
# `CountMinSketch`), sharding keys, content fingerprints. The output matches
# the C reference `rapidhash_withSeed` and Rust's
# `rapidhash::v3::rapidhash_v3_seeded(data, &RapidSecrets::seed_cpp(seed))`
# bit for bit, and it will never change: a future algorithm would be added
# as a new method, not by changing `v3`.
#
# ```
# require "rapidhash"
#
# Rapidhash.v3("hello")                   # => 0x... (the same on every run and machine)
# Rapidhash.v3("hello", seed: 42)         # a different, equally stable value
# Rapidhash.v3(Bytes[1, 2, 3])            # raw bytes
# Rapidhash.of(42) == Rapidhash.of(42_u8) # => true (integers hash by value)
# ```
#
# Rapidhash is not a cryptographic hash and is not designed to resist
# hash-flooding attacks: do not use it where an attacker chooses the keys
# and benefits from collisions, unless the seed is secret.
#
# NOTE: To use `Rapidhash`, you must explicitly import it with `require "rapidhash"`
module Rapidhash
  # The default secrets of the reference implementation.
  private SECRET0 = 0x2d358dccaa6c78a5_u64
  private SECRET1 = 0x8bb84b93962eacc9_u64
  private SECRET2 = 0x4b33a62ed433d4a3_u64
  private SECRET3 = 0x4d5a2da51de1aa47_u64
  private SECRET4 = 0xa0761d6478bd642f_u64
  private SECRET5 = 0xe7037ed1a0b428db_u64
  private SECRET6 = 0x90ed1765281c388c_u64

  # Returns the rapidhash V3 of *data* with the given *seed*.
  def self.v3(data : Bytes, seed : UInt64 = 0_u64) : UInt64
    hash_premixed(data.to_unsafe, data.size, premix(seed))
  end

  # Returns the rapidhash V3 of the bytes of *data* with the given *seed*.
  def self.v3(data : String, seed : UInt64 = 0_u64) : UInt64
    hash_premixed(data.to_unsafe, data.bytesize, premix(seed))
  end

  # Returns a stable hash of *value*, as `v3` does for bytes, defined for:
  #
  # * `String` and `Bytes`: `v3` of their bytes.
  # * `Char`: the hash of the one-character `String`.
  # * Integers: by value, so `1`, `1_i64` and `1_u8` hash alike. The value
  #   is widened to 128 bits (two's complement) and hashed as those 16
  #   little-endian bytes.
  # * Floats: by value, so `1.5_f32` and `1.5` hash alike; `-0.0` hashes as
  #   `0.0` and every NaN as the same NaN. A float never hashes like the
  #   integer of the same value.
  # * Any other type that defines `rapidhash(seed : UInt64) : UInt64`, which
  #   lets an application make its own types usable as sketch items (for
  #   example by hashing a canonical byte encoding with `v3`).
  def self.of(value, seed : UInt64 = 0_u64) : UInt64
    of_premixed(value, premix(seed))
  end

  # Applies the reference implementation's seed transformation. Hashing
  # with `hash_premixed` and a premixed seed equals `v3` with the raw seed,
  # without repeating the transformation on every call.
  #
  # :nodoc:
  @[AlwaysInline]
  def self.premix(seed : UInt64) : UInt64
    seed ^ mix(seed ^ SECRET2, SECRET1)
  end

  # `of` with an already premixed *seed*. One method with a `case` rather
  # than one overload per type: an overload set hands a union argument to
  # the unrestricted fallback whole, while `case` narrows each member (and
  # resolves at compile time for a concrete type).
  #
  # :nodoc:
  @[AlwaysInline]
  def self.of_premixed(value, seed : UInt64) : UInt64
    case value
    when String
      hash_premixed(value.to_unsafe, value.bytesize, seed)
    when Bytes
      hash_premixed(value.to_unsafe, value.size, seed)
    when Int::Signed
      wide = value.to_i128
      hash16(wide.to_u64!, (wide >> 64).to_u64!, seed)
    when Int::Unsigned
      wide = value.to_u128
      hash16(wide.to_u64!, (wide >> 64).to_u64!, seed)
    when Float::Primitive
      float = value.to_f64
      float = 0.0 if float == 0.0
      # One canonical quiet NaN (`0.0 / 0.0` sets the sign bit on x86).
      bits = float.nan? ? 0x7ff8000000000000_u64 : float.unsafe_as(UInt64)
      # The 8-byte path of `hash_premixed`: both reads see the same word.
      finish(bits, bits, seed ^ 8_u64, 8_u64)
    when Char
      bytes = uninitialized UInt8[4]
      size = 0
      value.each_byte do |byte|
        bytes[size] = byte
        size += 1
      end
      hash_premixed(bytes.to_unsafe, size, seed)
    else
      value.rapidhash(seed)
    end
  end

  # The 16-byte path of `hash_premixed` for a word pair already in
  # registers.
  @[AlwaysInline]
  private def self.hash16(lo : UInt64, hi : UInt64, seed : UInt64) : UInt64
    finish(lo, hi, seed ^ 16_u64, 16_u64)
  end

  # Hashes *size* bytes at *ptr* with an already premixed *seed*.
  #
  # :nodoc:
  def self.hash_premixed(ptr : UInt8*, size : Int32, seed : UInt64) : UInt64
    len = size.to_u64!
    if size <= 16
      a = 0_u64
      b = 0_u64
      if size >= 4
        seed ^= len
        if size >= 8
          a = read64(ptr)
          b = read64(ptr + (size - 8))
        else
          a = read32(ptr)
          b = read32(ptr + (size - 4))
        end
      elsif size > 0
        a = (ptr[0].to_u64 << 45) | ptr[size - 1].to_u64
        b = ptr[size >> 1].to_u64
      end
      finish(a, b, seed, len)
    else
      hash_long(ptr, size, seed)
    end
  end

  @[AlwaysInline]
  private def self.finish(a : UInt64, b : UInt64, seed : UInt64, remainder : UInt64) : UInt64
    a ^= SECRET1
    b ^= seed
    product = a.to_u128 &* b.to_u128
    a = product.to_u64!
    b = (product >> 64).to_u64!
    mix(a ^ 0xaaaaaaaaaaaaaaaa_u64, b ^ SECRET1 ^ remainder)
  end

  @[NoInline]
  private def self.hash_long(data : UInt8*, size : Int32, seed : UInt64) : UInt64
    p = data
    rest = size
    if rest > 112
      see1 = see2 = see3 = see4 = see5 = see6 = seed
      while rest > 224
        seed = mix(read64(p) ^ SECRET0, read64(p + 8) ^ seed)
        see1 = mix(read64(p + 16) ^ SECRET1, read64(p + 24) ^ see1)
        see2 = mix(read64(p + 32) ^ SECRET2, read64(p + 40) ^ see2)
        see3 = mix(read64(p + 48) ^ SECRET3, read64(p + 56) ^ see3)
        see4 = mix(read64(p + 64) ^ SECRET4, read64(p + 72) ^ see4)
        see5 = mix(read64(p + 80) ^ SECRET5, read64(p + 88) ^ see5)
        see6 = mix(read64(p + 96) ^ SECRET6, read64(p + 104) ^ see6)
        seed = mix(read64(p + 112) ^ SECRET0, read64(p + 120) ^ seed)
        see1 = mix(read64(p + 128) ^ SECRET1, read64(p + 136) ^ see1)
        see2 = mix(read64(p + 144) ^ SECRET2, read64(p + 152) ^ see2)
        see3 = mix(read64(p + 160) ^ SECRET3, read64(p + 168) ^ see3)
        see4 = mix(read64(p + 176) ^ SECRET4, read64(p + 184) ^ see4)
        see5 = mix(read64(p + 192) ^ SECRET5, read64(p + 200) ^ see5)
        see6 = mix(read64(p + 208) ^ SECRET6, read64(p + 216) ^ see6)
        p += 224
        rest -= 224
      end
      if rest > 112
        seed = mix(read64(p) ^ SECRET0, read64(p + 8) ^ seed)
        see1 = mix(read64(p + 16) ^ SECRET1, read64(p + 24) ^ see1)
        see2 = mix(read64(p + 32) ^ SECRET2, read64(p + 40) ^ see2)
        see3 = mix(read64(p + 48) ^ SECRET3, read64(p + 56) ^ see3)
        see4 = mix(read64(p + 64) ^ SECRET4, read64(p + 72) ^ see4)
        see5 = mix(read64(p + 80) ^ SECRET5, read64(p + 88) ^ see5)
        see6 = mix(read64(p + 96) ^ SECRET6, read64(p + 104) ^ see6)
        p += 112
        rest -= 112
      end
      seed ^= see1
      see2 ^= see3
      see4 ^= see5
      seed ^= see6
      see2 ^= see4
      seed ^= see2
    end

    if rest > 16
      seed = mix(read64(p) ^ SECRET2, read64(p + 8) ^ seed)
      if rest > 32
        seed = mix(read64(p + 16) ^ SECRET2, read64(p + 24) ^ seed)
        if rest > 48
          seed = mix(read64(p + 32) ^ SECRET1, read64(p + 40) ^ seed)
          if rest > 64
            seed = mix(read64(p + 48) ^ SECRET1, read64(p + 56) ^ seed)
            if rest > 80
              seed = mix(read64(p + 64) ^ SECRET2, read64(p + 72) ^ seed)
              if rest > 96
                seed = mix(read64(p + 80) ^ SECRET1, read64(p + 88) ^ seed)
              end
            end
          end
        end
      end
    end

    remainder = rest.to_u64!
    a = read64(data + (size - 16)) ^ remainder
    b = read64(data + (size - 8))
    finish(a, b, seed, remainder)
  end

  @[AlwaysInline]
  private def self.mix(a : UInt64, b : UInt64) : UInt64
    product = a.to_u128 &* b.to_u128
    product.to_u64! ^ (product >> 64).to_u64!
  end

  # Unaligned little-endian reads (Crystal only targets little-endian
  # platforms). The copy compiles to a single unaligned load.
  @[AlwaysInline]
  private def self.read64(ptr : UInt8*) : UInt64
    word = uninitialized UInt64
    pointerof(word).as(UInt8*).copy_from(ptr, 8)
    word
  end

  @[AlwaysInline]
  private def self.read32(ptr : UInt8*) : UInt64
    word = uninitialized UInt32
    pointerof(word).as(UInt8*).copy_from(ptr, 4)
    word.to_u64
  end
end
