require "spec"
require "./spec_helper"

describe "GC" do
  pending_wasm32 describe: "abort on OOM" do
    it "aborts with an error message when an allocation is too large for the heap" do
      status, _, error = compile_and_run_source <<-CRYSTAL
        GC.max_heap_size = 64_u64 * 1024 * 1024
        GC.malloc(1_u64 << 30)
        CRYSTAL

      status.normal_exit?.should be_true
      status.exit_code.should eq(1)
      error.should contain("Out of memory: failed to allocate 1073741824 bytes")
    end

    it "aborts with an error message when the heap is exhausted" do
      status, _, error = compile_and_run_source <<-CRYSTAL
        GC.max_heap_size = 32_u64 * 1024 * 1024
        bufs = [] of Bytes
        loop do
          bufs << Bytes.new(1024 * 1024)
        end
        CRYSTAL

      status.normal_exit?.should be_true
      status.exit_code.should eq(1)
      error.should contain("Out of memory: failed to allocate")
    end
  end

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

        # idempotent: a redundant restart is safe
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
