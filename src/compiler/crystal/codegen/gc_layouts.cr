require "./codegen"

# Emits the per-type pointer layout tables used by the runtime's precise
# object marker (`-Dgc_precise`, see `GC.malloc_object` in `src/gc/boehm.cr`).
#
# Class instances whose instance variables may hold pointers are allocated in a
# dedicated libgc object kind. Instead of scanning every word of such an object
# conservatively, libgc calls back into the runtime, which reads the type id
# from the object's first word and pushes only the words listed in that type's
# layout. The layouts are computed here, from the same LLVM struct layouts the
# object code uses, and emitted as constant data:
#
# * `__crystal_gc_layouts` points to a table with `__crystal_gc_layouts_count`
#   entries, indexed by type id;
# * each entry is either null or points to `i32 n, i32 offset[n]`, the word
#   offsets (from the object start) that may hold a pointer into the GC heap.
#
# A null entry means "no precise layout": the marker then scans the whole
# object conservatively, which is always safe. That is what happens for
# pointer-free classes (allocated atomically, never marked at all), for types
# whose layout this code declines to describe, and for a free-list object,
# whose first word is a link rather than a type id.
#
# Everything here errs on the side of scanning too much: a word that is only
# sometimes a pointer (the payload of a mixed union) is always listed, while
# leaving a real pointer out would let the collector free a live object.
class Crystal::CodeGenVisitor
  def define_gc_layouts
    # Only when the prelude allocates objects precisely
    return unless crystal_malloc_object_fun

    llvm_id = @program.llvm_id
    count = llvm_id.id_count
    ptr = @main_llvm_context.void_pointer
    int32 = @main_llvm_context.int32
    word = @main_llvm_typer.pointer_size.to_u64

    entries = Array(LLVM::Value).new(count, ptr.null)
    llvm_id.ids.each do |type, (_min, id)|
      container = type.as?(InstanceVarContainer) || next
      # the same predicate `allocate_aggregate` uses to pick the pointer-bearing
      # allocator; everything else never reaches the precise marker
      next if container.struct? || container.metaclass? || container.module? || container.abstract? || container.is_a?(GenericClassType)
      next unless container.all_instance_vars.each_value.any? &.type.has_inner_pointers?

      offsets = gc_pointer_offsets(container)
      # `nil` (no precise description) and misaligned words both leave the
      # conservative null entry in place
      next unless offsets && offsets.all? { |offset| offset % word == 0 }

      values = [int32.const_int(offsets.size)]
      offsets.each { |offset| values << int32.const_int(offset // word) }
      data = @main_mod.globals.add(int32.array(values.size), "#{GC_LAYOUTS_NAME}.#{id}")
      data.initializer = int32.const_array(values)
      data.linkage = LLVM::Linkage::Private
      data.global_constant = true
      entries[id] = data
    end

    table = @main_mod.globals.add(ptr.array(count), "#{GC_LAYOUTS_NAME}.table")
    table.initializer = ptr.const_array(entries)
    table.linkage = LLVM::Linkage::Private
    table.global_constant = true

    # The runtime declares both as external lib variables; if it did so in the
    # main module the declarations already exist and just get their definition.
    layouts = @main_mod.globals[GC_LAYOUTS_NAME]? || @main_mod.globals.add(ptr, GC_LAYOUTS_NAME)
    layouts.initializer = table
    layouts.global_constant = true

    layouts_count = @main_mod.globals[GC_LAYOUTS_COUNT_NAME]? || @main_mod.globals.add(int32, GC_LAYOUTS_COUNT_NAME)
    layouts_count.initializer = int32.const_int(count)
    layouts_count.global_constant = true
  end

  # Byte offsets, from the start of an instance of the class *type*, of every
  # word that may hold a pointer into the GC heap. Returns `nil` when some
  # instance variable's layout can't be described precisely.
  def gc_pointer_offsets(type) : Array(UInt64)?
    offsets = [] of UInt64
    struct_type = @main_llvm_typer.llvm_struct_type(type)
    # element 0 of a class struct is the type id, instance vars follow
    first_element = type.struct? ? 0 : 1
    type.all_instance_vars.each_value.with_index do |ivar, i|
      base = @main_llvm_typer.offset_of(struct_type, first_element + i)
      return nil unless collect_gc_pointer_offsets(ivar.type, base, offsets)
    end
    offsets
  end

  # Appends to *offsets* the pointer-word offsets of a value of *type* stored
  # at byte offset *base*. Returns `false` when *type* has no precise layout.
  # Mirrors the LLVM layouts in `LLVMTyper`.
  private def collect_gc_pointer_offsets(type : Type, base : UInt64, offsets : Array(UInt64)) : Bool
    typer = @main_llvm_typer
    type = type.remove_indirection
    case type
    when AliasType
      collect_gc_pointer_offsets(type.aliased_type, base, offsets)
    when TypeDefType
      collect_gc_pointer_offsets(type.typedef, base, offsets)
    when PrimitiveType, NilType, VoidType, NoReturnType, EnumType
      true
    when MetaclassType, GenericClassInstanceMetaclassType, GenericModuleInstanceMetaclassType, VirtualMetaclassType
      # a type id
      true
    when NonGenericModuleType, GenericClassType
      # an `i1` placeholder: the module or generic class has no implementors
      true
    when PointerInstanceType
      offsets << base
      true
    when ProcInstanceType, NilableProcType
      # `{fn, context}`: only the closure context may live on the GC heap
      offsets << base + typer.offset_of(typer.proc_type, 1)
      true
    when NilableType, ReferenceUnionType, NilableReferenceUnionType
      offsets << base
      true
    when VirtualType
      # struct virtual types became a union in `remove_indirection`
      return false if type.struct?
      offsets << base
      true
    when MixedUnionType
      return true unless type.has_inner_pointers?
      # `{i32 type_id, [n x iN] value}`: which words hold pointers depends on
      # the runtime type, so every word of the value may
      llvm_type = typer.llvm_type(type)
      value_offset = typer.offset_of(llvm_type, 1)
      value_size = typer.size_of(llvm_type.struct_element_types[1])
      word = typer.pointer_size.to_u64
      (value_size // word).times do |i|
        offsets << base + value_offset + i * word
      end
      true
    when StaticArrayInstanceType
      element_type = type.element_type
      return true unless element_type.has_inner_pointers?
      stride = typer.size_of(typer.llvm_embedded_type(element_type))
      type.size.as(NumberLiteral).value.to_i.times do |i|
        return false unless collect_gc_pointer_offsets(element_type, base + i * stride, offsets)
      end
      true
    when TupleInstanceType
      llvm_type = typer.llvm_type(type)
      type.tuple_types.each_with_index do |tuple_type, i|
        return false unless collect_gc_pointer_offsets(tuple_type, base + typer.offset_of(llvm_type, i), offsets)
      end
      true
    when NamedTupleInstanceType
      llvm_type = typer.llvm_type(type)
      type.entries.each_with_index do |entry, i|
        return false unless collect_gc_pointer_offsets(entry.type, base + typer.offset_of(llvm_type, i), offsets)
      end
      true
    when ReferenceStorageType
      # the class struct itself, type id included
      inner = gc_pointer_offsets(type.reference_type)
      return false unless inner
      inner.each { |offset| offsets << base + offset }
      true
    when InstanceVarContainer
      if type.struct?
        # a C union overlays its members: no single layout
        return !type.has_inner_pointers? if type.extern_union?
        inner = gc_pointer_offsets(type)
        return false unless inner
        inner.each { |offset| offsets << base + offset }
        true
      else
        # a reference
        offsets << base
        true
      end
    else
      false
    end
  end
end
