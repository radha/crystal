module Binary
  # Order in which bits are packed into bytes by `BitReader`, `BitWriter`
  # and `bits:` fields of a `Binary::Format`.
  #
  # * `Msb`: the first bit written occupies the most significant bit of the
  #   first byte. Network protocol headers and most codecs use this order.
  # * `Lsb`: the first bit written occupies the least significant bit of the
  #   first byte. DEFLATE uses this order.
  enum BitOrder
    Msb
    Lsb
  end
end
