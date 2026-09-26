require "benchmark"
require "csv"
short = "hello world"
med = "a cell with \"quotes\" and more text in it, plus a \"second\" pair"
long_plain = "abcdefghij" * 100
long_quotes = ("abc\"def\"ghij" * 80)
utf = "héllo wörld ça va \"bien\" " * 40
cjk = "日本語のテキスト" * 43
io = IO::Memory.new
sink = 0_i64
Benchmark.ips do |x|
  {% for name in %w(short med long_plain long_quotes utf cjk) %}
    x.report({{name}}) do
      io.clear
      b = CSV::Builder.new(io, quoting: :all)
      b.row { |r| r << {{name.id}} }
      sink &+= io.bytesize
    end
  {% end %}
end
puts sink
