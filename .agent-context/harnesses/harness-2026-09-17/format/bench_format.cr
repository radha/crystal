# .remember/harness-2026-09-17/format/bench_format.cr
require "binary"
require "benchmark"

struct RpcHeader
  include Binary::Format
  field type : UInt8
  field flags : UInt8
  field stream_id : UInt32
  field length : UInt32
end

struct Column
  include Binary::Format
  field length : Int32, value: ->{ value.try(&.size) || -1 }
  field value : Bytes?, length: ->{ length }, if: ->{ length >= 0 }
end

struct DataRow
  include Binary::Format
  field type : UInt8 = 'D'.ord.to_u8
  field length : Int32, size_of: :rest, including_self: true
  field count : Int16
  field columns : Array(Column), count: :count
end

header = RpcHeader.new(type: 1_u8, flags: 2_u8, stream_id: 3_u32, length: 4_u32)
header_bytes = header.to_slice
row = DataRow.new(columns: Array.new(10) { |i| Column.new(value: "value-#{i}".to_slice) })
row_bytes = row.to_slice
buf = Bytes.new(64)
sink = IO::Memory.new(4096)

Benchmark.ips do |x|
  x.report("header from_slice") { RpcHeader.from_slice(header_bytes) }
  x.report("header write_to") { header.write_to(buf) }
  x.report("header write(io)") { sink.rewind; header.write(sink) }
  x.report("datarow from_slice") { DataRow.from_slice(row_bytes) }
  x.report("datarow write(io)") { sink.rewind; row.write(sink) }
  x.report("datarow to_slice") { row.to_slice }
end
