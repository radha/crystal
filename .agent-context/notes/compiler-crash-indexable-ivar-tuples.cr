# Crystal 1.21.0 (LLVM 20): codegen crashes with "Element not found (Enumerable::NotFoundError)"
# / "you have found a bug in the Crystal compiler". Trigger: an ivar restricted to
# Indexable(String) assigned tuples of different sizes, indexed inside a block of
# Tuple#each_with_index. Found 2026-09-26 via Postgres::CopyRows; worked around by
# storing columns.to_a. Not yet reported upstream.
class Rows
  def initialize(@columns : Indexable(String))
  end

  def row(*values) : Nil
    values.each_with_index do |value, i|
      raise "column #{@columns[i]}: bad" if value.nil?
    end
  end
end

Rows.new({"a", "b"}).row(1, 2)
Rows.new({"a"}).row(1)
