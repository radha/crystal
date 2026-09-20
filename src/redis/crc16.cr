module Redis
  # CRC16 with the XMODEM parameters (polynomial `0x1021`, initial value
  # 0, no reflection, no final XOR): the checksum Redis Cluster hashes keys
  # with. `checksum("123456789")` is `0x31C3`.
  module CRC16
    # :nodoc:
    TABLE = begin
      table = StaticArray(UInt16, 256).new(0_u16)
      256.times do |i|
        crc = (i << 8).to_u16
        8.times do
          crc = (crc & 0x8000_u16) != 0 ? ((crc << 1) ^ 0x1021_u16) : (crc << 1)
        end
        table[i] = crc
      end
      table
    end

    # Returns the checksum of *data*.
    def self.checksum(data : Bytes) : UInt16
      crc = 0_u16
      data.each do |byte|
        crc = (crc << 8) ^ TABLE[((crc >> 8) ^ byte.to_u16).to_u8!]
      end
      crc
    end

    # :ditto:
    def self.checksum(data : String) : UInt16
      checksum(data.to_slice)
    end
  end
end
