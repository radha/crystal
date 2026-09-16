require "spec"

{% if flag?(:gc_precise) %}
  class GCSpecPreciseNode
    getter value : Int32
    getter next : GCSpecPreciseNode?
    getter payload : Int64
    @a = 0x7fff_ffff_ffff_0000_i64
    @b = 1.5

    def initialize(@value, @next)
      @payload = @value.to_i64 * 3
    end
  end
{% end %}
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

    it "defaults the free-space divisor to 2" do
      GC.free_space_divisor.should eq(2) unless ENV["CRYSTAL_GC_FREE_SPACE_DIVISOR"]?
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

    {% if flag?(:gc_precise) %}
      describe ".malloc_object" do
        it "returns cleared memory" do
          ptr = GC.malloc_object(64).as(UInt64*)
          8.times { |i| ptr[i].should eq(0) }
        end

        it "keeps objects alive through precisely marked pointers" do
          # a long chain reachable only through instance variables, with
          # pointer-free payload around every link
          head = GCSpecPreciseNode.new(0, nil)
          200_000.times { |i| head = GCSpecPreciseNode.new(i + 1, head) }

          3.times { GC.collect }
          # allocate garbage so freed memory would get reused and corrupted
          100_000.times { |i| GCSpecPreciseNode.new(-1, nil) }
          GC.collect

          node = head
          count = 0
          while node
            node.value.should eq(200_000 - count)
            node.payload.should eq(node.value.to_i64 * 3)
            node = node.next
            count += 1
          end
          count.should eq(200_001)
        end
      end
    {% end %}

    describe ".shrink_atomic" do
      it "keeps the allocation when libgc would reclaim nothing" do
        # small object: 64-byte slot, keeping >= 32 bytes returns the same pointer
        ptr = GC.malloc_atomic(64).as(UInt8*)
        ptr.fill(64, 0xAB_u8)
        GC.shrink_atomic(ptr, 40).should eq(ptr)
        ptr[39].should eq(0xAB_u8)

        # whole-block object: 1 MiB, keeping >= 512 KiB returns the same pointer
        big = GC.malloc_atomic(1 << 20).as(UInt8*)
        big.fill(1 << 20, 0xCD_u8)
        GC.shrink_atomic(big, 600_000).should eq(big)
        big[599_999].should eq(0xCD_u8)
      end

      it "reallocates and preserves the contents when shrinking below half" do
        ptr = GC.malloc_atomic(1 << 16).as(UInt8*)
        ptr.fill(1 << 16, 0xEF_u8)
        small = GC.shrink_atomic(ptr, 100)
        100.times { |i| small[i].should eq(0xEF_u8) }
        # the shrunk slot really is smaller
        LibGC.size(small.as(Void*)).should be < (1 << 16)
      end
    end
  {% end %}
end
