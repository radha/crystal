require "spec"

describe "GC" do
  it "compiles GC.stats" do
    typeof(GC.stats).should eq(GC::Stats)
  end

  it "raises if calling enable when not disabled" do
    expect_raises(Exception, "GC is not disabled") do
      GC.enable
    end
  end

  it ".stats" do
    GC.stats.should be_a(GC::Stats)
  end

  it ".prof_stats" do
    GC.prof_stats.should be_a(GC::ProfStats)
  end

  {% unless flag?(:gc_none) %}
    it "enables parallel marking at startup" do
      # `GC.init` calls `GC_start_mark_threads`, so a multi-core build with a
      # recent enough libgc should be marking in parallel rather than on a
      # single core. libgc reports the marker-thread count via `GC_get_parallel`
      # (0 when serial, which is the only option on a single core or old libgc).
      {% if LibGC.has_method?(:get_parallel) %}
        if System.cpu_count > 1
          LibGC.get_parallel.should be > 0
        end

        # idempotent: a redundant restart (as happens in a forked child) is safe
        GC.start_mark_threads
      {% end %}
    end

    it ".free_space_divisor round-trips" do
      original = GC.free_space_divisor
      begin
        GC.free_space_divisor = 7
        GC.free_space_divisor.should eq(7)
      ensure
        GC.free_space_divisor = original
      end
    end

    it ".free_space_divisor= rejects non-positive values" do
      expect_raises(ArgumentError) { GC.free_space_divisor = 0 }
    end

    it ".presize_heap grows the heap and never shrinks it" do
      GC.presize_heap(0) # no-op, must not shrink
      before = GC.stats.heap_size
      GC.presize_heap(before + 16 * 1024 * 1024)
      GC.stats.heap_size.should be >= before + 16 * 1024 * 1024
    end
  {% end %}
end
