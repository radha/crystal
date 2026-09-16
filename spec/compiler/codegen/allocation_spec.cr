require "../../spec_helper"

# The prelude defines `__crystal_malloc64` & co.; here they are stubbed so the
# emitted IR can be inspected without it.
private ALLOCATORS = <<-CRYSTAL
  fun __crystal_malloc64(size : UInt64) : Void*
    Pointer(Void).new(0_u64)
  end

  fun __crystal_malloc_atomic64(size : UInt64) : Void*
    Pointer(Void).new(0_u64)
  end
  CRYSTAL

describe "Code gen: allocation" do
  describe "clearing" do
    it "doesn't clear an object allocated with GC.malloc, which returns cleared memory" do
      mod = codegen(<<-CRYSTAL, single_module: true)
        #{ALLOCATORS}

        class Foo
          @ptr = Pointer(Int32).new(0_u64)
          @x = 1
        end

        Foo.new
        CRYSTAL
      mod.to_s.should_not contain("llvm.memset")
    end

    it "still clears an object allocated with GC.malloc_atomic" do
      mod = codegen(<<-CRYSTAL, single_module: true)
        #{ALLOCATORS}

        class Foo
          @x = 1
          @y = 2.5
        end

        Foo.new
        CRYSTAL
      mod.to_s.should contain("llvm.memset")
    end

    it "still clears an object when falling back to libc malloc" do
      mod = codegen(<<-CRYSTAL, single_module: true)
        class Foo
          @ptr = Pointer(Int32).new(0_u64)
        end

        Foo.new
        CRYSTAL
      mod.to_s.should contain("llvm.memset")
    end

    it "doesn't clear a pointer buffer whose elements have inner pointers" do
      mod = codegen(<<-CRYSTAL, single_module: true)
        #{ALLOCATORS}

        Pointer(Pointer(Int32)).malloc(3_u64)
        CRYSTAL
      mod.to_s.should_not contain("llvm.memset")
    end

    it "still clears a pointer-free pointer buffer" do
      mod = codegen(<<-CRYSTAL, single_module: true)
        #{ALLOCATORS}

        Pointer(Int32).malloc(3_u64)
        CRYSTAL
      mod.to_s.should contain("llvm.memset")
    end

    it "still clears memory given to Reference.pre_initialize" do
      mod = codegen(<<-CRYSTAL, single_module: true)
        #{ALLOCATORS}

        class Foo
          @ptr = Pointer(Int32).new(0_u64)
        end

        buf = Pointer(Void).new(0_u64)
        Foo.pre_initialize(buf)
        CRYSTAL
      mod.to_s.should contain("llvm.memset")
    end

    it "keeps zero-initialized instance variables at zero and runs initializers" do
      # a real, clearing allocator (the IR-only specs above can stub it out
      # with a null pointer, this one actually runs)
      run(<<-CRYSTAL).to_i.should eq(42)
        lib LibC
          fun calloc(count : UInt64, size : UInt64) : Void*
        end

        fun __crystal_malloc64(size : UInt64) : Void*
          LibC.calloc(1_u64, size)
        end

        class Foo
          @ptr = Pointer(Int32).new(0_u64)
          @a : Int32?
          @b = 40

          def sum
            (@ptr.address == 0 ? 2 : 0) &+ (@a.nil? ? 0 : 100) &+ @b
          end
        end

        Foo.new.sum
        CRYSTAL
    end
  end

  describe "allocator attributes" do
    it "marks the GC entry points as allocators" do
      ir = codegen(<<-CRYSTAL, single_module: true).to_s
        #{ALLOCATORS}

        fun __crystal_realloc64(ptr : Void*, size : UInt64) : Void*
          Pointer(Void).new(0_u64)
        end

        class Foo
          @ptr = Pointer(Int32).new(0_u64)
        end

        Foo.new
        Pointer(Int32).malloc(3_u64)
        Pointer(Int32).malloc(3_u64).realloc(4_u64)
        CRYSTAL

      ir.should match(/define .*noalias ptr @__crystal_malloc64/)
      ir.should match(/define .*noalias ptr @__crystal_malloc_atomic64/)
      ir.should match(/define .*noalias ptr @__crystal_realloc64/)
      ir.should contain("allocsize(0)")
      ir.should contain("allocsize(1)")
      {% unless LibLLVM::IS_LT_150 %}
        ir.should contain(%(allockind("alloc,zeroed")))
        ir.should contain(%(allockind("alloc,uninitialized")))
        ir.should contain(%(allockind("realloc")))
        ir.should contain(%("alloc-family"="GC_malloc"))
      {% end %}
    end

    it "marks the libgc allocators as allocators" do
      ir = codegen(<<-CRYSTAL, single_module: true).to_s
        lib LibGC
          fun malloc = GC_malloc(size : UInt64) : Void*
          fun malloc_atomic = GC_malloc_atomic(size : UInt64) : Void*
          fun free = GC_free(ptr : Void*)
        end

        LibGC.free(LibGC.malloc(1))
        LibGC.malloc_atomic(1)
        CRYSTAL

      ir.should match(/declare noalias ptr @GC_malloc\(/)
      ir.should match(/declare noalias ptr @GC_malloc_atomic\(/)
      {% unless LibLLVM::IS_LT_150 %}
        ir.should contain(%(allockind("free")))
      {% end %}
    end

    it "declares the attributes on the callee in every module" do
      ir = codegen(<<-CRYSTAL, single_module: false)
        #{ALLOCATORS}

        class Foo
          @ptr = Pointer(Int32).new(0_u64)

          def foo
            Foo.new
          end
        end

        Foo.new.foo
        CRYSTAL

      # every module that references the allocator sees a noalias declaration
      ir.to_s.should match(/(declare|define) .*noalias ptr @__crystal_malloc64/)
    end
  end
end
