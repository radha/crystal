require "benchmark"
r = Random.new(42)
ints = Array.new(1000) { r.rand(100_000) }
contig = Deque(Int32).new(ints)
wrapped = Deque(Int32).new(1000)
600.times { |i| wrapped.push ints[i] }
400.times { wrapped.shift }
ints.each { |v| wrapped.push v }
strs = Deque(String).new(ints.map(&.to_s))
sink = 0_i64
Benchmark.ips do |x|
  x.report("contig sort!") { d = contig.dup; d.sort!; sink &+= d[0] }
  x.report("wrapped sort!") { d = wrapped.dup; d.sort!; sink &+= d[0] }
  x.report("contig unstable_sort!") { d = contig.dup; d.unstable_sort!; sink &+= d[0] }
  x.report("contig sort_by!") { d = contig.dup; d.sort_by! { |v| -v }; sink &+= d[0] }
  x.report("contig sort!{block}") { d = contig.dup; d.sort! { |a, b| b <=> a }; sink &+= d[0] }
  x.report("strings sort!") { d = strs.dup; d.sort!; sink &+= d[0].bytesize }
  x.report("dup only") { d = contig.dup; sink &+= d[0] }
end
puts sink
