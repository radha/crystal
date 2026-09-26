require "benchmark"
require "json"

record Point, x : Float64, y : Float64, id : Int64 do
  include JSON::Serializable
end

strings_long = JSON.build { |j| j.array { 200.times { |i| j.string("abcdefghij" * 10 + i.to_s) } } }
keys = JSON.build { |j| j.array { 100.times { j.object { 20.times { |i| j.field("key#{i}", "value#{i}") } } } } }
unicode = JSON.build { |j| j.array { 200.times { j.string("héllo wörld ça va " * 5) } } }
escapes = JSON.build { |j| j.array { 200.times { j.string("line one\nline two\t\"quoted\" " * 3) } } }
ints = JSON.build { |j| j.array { 5000.times { |i| j.number(i * 7919 - 100000) } } }
floats = JSON.build { |j| j.array { 5000.times { |i| j.number(i * 0.37 - 100.5) } } }
points = JSON.build { |j| j.array { 1000.times { |i| j.object { j.field("x", i * 0.5); j.field("y", i * 1.5); j.field("id", i) } } } }
sink = 0_i64
Benchmark.ips do |x|
  {% for name in %w(strings_long keys unicode escapes) %}
    x.report("IO parse " + {{name}}) { sink &+= JSON.parse(IO::Memory.new({{name.id}})).as_a.size }
    x.report("IO skip " + {{name}}) { p = JSON::PullParser.new(IO::Memory.new({{name.id}})); p.skip; sink &+= 1 }
  {% end %}
  x.report("IO from_json points") { sink &+= Array(Point).from_json(IO::Memory.new(points)).size }
  {% for name in %w(ints floats points) %}
    x.report("String parse " + {{name}}) { sink &+= JSON.parse({{name.id}}).as_a.size }
  {% end %}
  x.report("String from_json ints") { sink &+= Array(Int64).from_json(ints).size }
  x.report("String from_json floats") { sink &+= Array(Float64).from_json(floats).size }
  x.report("String from_json points") { sink &+= Array(Point).from_json(points).size }
  x.report("String read_raw floats") { p = JSON::PullParser.new(floats); p.read_array { sink &+= p.read_raw.bytesize } }
end
puts sink
