require "c/sys/file"
require "file/error"

{% if flag?(:darwin) %}
  lib LibC
    # <sys/clonefile.h>: clones (reflinks) the file open as *src* to the path
    # *dst* relative to the directory *dst_dirfd*.
    fun fclonefileat(src : Int, dst_dirfd : Int, dst : Char*, flags : UInt32) : Int
  end
{% elsif flag?(:linux) && !flag?(:android) %}
  lib LibC
    # <unistd.h>: copies a range of data between two file descriptors in the
    # kernel (Linux 4.5+, glibc 2.27+ / musl 1.2.2+; excluded on Android, where
    # it is only exposed by the NDK from API 34). `off_in`/`off_out` are the
    # 64-bit `loff_t*` offsets; passing null uses and advances each descriptor's
    # own file offset.
    fun copy_file_range(fd_in : Int, off_in : Int64*, fd_out : Int, off_out : Int64*, len : SizeT, flags : UInt) : SSizeT
  end
{% end %}

# :nodoc:
module Crystal::System::File
  def self.open(filename : String, mode : String, perm : Int32 | ::File::Permissions, blocking : Bool?) : {FileDescriptor::Handle, Bool}
    perm = ::File::Permissions.new(perm) if perm.is_a? Int32

    case result = EventLoop.current.open(filename, open_flag(mode), perm, blocking)
    in Tuple(FileDescriptor::Handle, Bool)
      result
    in Errno
      raise ::File::Error.from_os_error("Error opening file with mode '#{mode}'", result, file: filename)
    end
  end

  protected def system_init(mode : String, blocking : Bool) : Nil
  end

  def self.special_type?(fd)
    stat = uninitialized LibC::Stat
    ret = fstat(fd, pointerof(stat))
    # not checking for S_IFSOCK because we can't open(2) a socket
    ret != -1 && (stat.st_mode & LibC::S_IFMT).in?(LibC::S_IFCHR, LibC::S_IFIFO)
  end

  def self.info?(path : String, follow_symlinks : Bool) : ::File::Info?
    stat = uninitialized LibC::Stat
    if follow_symlinks
      ret = stat(path.check_no_null_byte, pointerof(stat))
    else
      ret = lstat(path.check_no_null_byte, pointerof(stat))
    end

    if ret == 0
      ::File::Info.new(stat)
    else
      if ::File::NotFoundError.os_error?(Errno.value)
        nil
      else
        raise ::File::Error.from_errno("Unable to get file info", file: path)
      end
    end
  end

  # On some systems, the symbols `stat`, `fstat` and `lstat` are not part of the GNU
  # shared library `libc.so` and instead provided by `libc_noshared.a`.
  # That makes them unavailable for dynamic runtime symbol lookup via `dlsym`
  # which we use for interpreted mode.
  # See https://github.com/crystal-lang/crystal/issues/11157#issuecomment-949640034 for details.
  # Linking against the internal counterparts `__xstat`, `__fxstat` and `__lxstat` directly
  # should work in both interpreted and compiled mode.

  def self.stat(path, stat)
    {% if LibC.has_method?(:__xstat) %}
      LibC.__xstat(LibC::STAT_VER, path, stat)
    {% else %}
      LibC.stat(path, stat)
    {% end %}
  end

  def self.fstat(path, stat)
    {% if LibC.has_method?(:__fxstat) %}
      LibC.__fxstat(LibC::STAT_VER, path, stat)
    {% else %}
      LibC.fstat(path, stat)
    {% end %}
  end

  def self.lstat(path, stat)
    {% if LibC.has_method?(:__lxstat) %}
      LibC.__lxstat(LibC::STAT_VER, path, stat)
    {% else %}
      LibC.lstat(path, stat)
    {% end %}
  end

  def self.info(path, follow_symlinks)
    info?(path, follow_symlinks) || raise ::File::Error.from_errno("Unable to get file info", file: path)
  end

  def self.exists?(path)
    accessible?(path, LibC::F_OK)
  end

  def self.readable?(path) : Bool
    accessible?(path, LibC::R_OK)
  end

  def self.writable?(path) : Bool
    accessible?(path, LibC::W_OK)
  end

  def self.executable?(path) : Bool
    accessible?(path, LibC::X_OK)
  end

  private def self.accessible?(path, flag)
    LibC.access(path.check_no_null_byte, flag) == 0
  end

  def self.chown(path, uid : Int, gid : Int, follow_symlinks)
    ret = if follow_symlinks
            LibC.chown(path, uid, gid)
          else
            LibC.lchown(path, uid, gid)
          end
    raise ::File::Error.from_errno("Error changing owner", file: path) if ret == -1
  end

  private def system_chown(uid : Int, gid : Int)
    ret = LibC.fchown(fd, uid, gid)
    raise ::File::Error.from_errno("Error changing owner", file: path) if ret == -1
  end

  def self.chmod(path, mode)
    if LibC.chmod(path, mode) == -1
      raise ::File::Error.from_errno("Error changing permissions", file: path)
    end
  end

  private def system_chmod(mode)
    if LibC.fchmod(fd, mode) == -1
      raise ::File::Error.from_errno("Error changing permissions", file: path)
    end
  end

  def self.delete(path, *, raise_on_missing : Bool) : Bool
    err = LibC.unlink(path.check_no_null_byte)
    if err != -1
      true
    elsif !raise_on_missing && ::File::NotFoundError.os_error?(Errno.value)
      false
    else
      raise ::File::Error.from_errno("Error deleting file", file: path)
    end
  end

  def self.realpath(path)
    realpath_ptr = LibC.realpath(path, nil)
    raise ::File::Error.from_errno("Error resolving real path", file: path) unless realpath_ptr
    String.new(realpath_ptr).tap { LibC.free(realpath_ptr.as(Void*)) }
  end

  def self.link(old_path, new_path)
    ret = LibC.link(old_path.check_no_null_byte, new_path.check_no_null_byte)
    raise ::File::Error.from_errno("Error creating link", file: old_path, other: new_path) if ret != 0
    ret
  end

  def self.symlink(old_path, new_path)
    ret = LibC.symlink(old_path.check_no_null_byte, new_path.check_no_null_byte)
    raise ::File::Error.from_errno("Error creating symlink", file: old_path, other: new_path) if ret != 0
    ret
  end

  def self.readlink(path, &) : String
    buf = uninitialized UInt8[4096]
    bytesize = LibC.readlink(path, buf, buf.size)
    if bytesize == -1
      if ::File::NotFoundError.os_error?(Errno.value) || Errno.value == Errno::EINVAL
        yield
      end

      raise ::File::Error.from_errno("Cannot read link", file: path)
    elsif bytesize == buf.size
      raise ::File::Error.from_os_error("Cannot read link", Errno::ENAMETOOLONG, file: path)
    else
      return String.new(buf.to_unsafe, bytesize)
    end
  end

  def self.rename(old_filename, new_filename) : ::File::Error?
    code = LibC.rename(old_filename.check_no_null_byte, new_filename.check_no_null_byte)
    if code != 0
      ::File::Error.from_errno("Error renaming file", file: old_filename, other: new_filename)
    end
  end

  def self.utime(atime : ::Time, mtime : ::Time, filename : String) : Nil
    ret =
      {% if LibC.has_method?("utimensat") %}
        timespecs = uninitialized LibC::Timespec[2]
        timespecs[0] = Crystal::System::Time.to_timespec(atime)
        timespecs[1] = Crystal::System::Time.to_timespec(mtime)
        LibC.utimensat(LibC::AT_FDCWD, filename, timespecs, 0)
      {% else %}
        timevals = uninitialized LibC::Timeval[2]
        timevals[0] = Crystal::System::Time.to_timeval(atime)
        timevals[1] = Crystal::System::Time.to_timeval(mtime)
        LibC.utimes(filename, timevals)
      {% end %}

    if ret != 0
      raise ::File::Error.from_errno("Error setting time on file", file: filename)
    end
  end

  private def system_utime(atime : ::Time, mtime : ::Time) : Nil
    ret = {% if LibC.has_method?("futimens") %}
            timespecs = uninitialized LibC::Timespec[2]
            timespecs[0] = Crystal::System::Time.to_timespec(atime)
            timespecs[1] = Crystal::System::Time.to_timespec(mtime)
            LibC.futimens(fd, timespecs)
          {% elsif LibC.has_method?("futimes") %}
            timevals = uninitialized LibC::Timeval[2]
            timevals[0] = Crystal::System::Time.to_timeval(atime)
            timevals[1] = Crystal::System::Time.to_timeval(mtime)
            LibC.futimes(fd, timevals)
          {% else %}
            {% raise "Missing futimens & futimes" %}
          {% end %}

    if ret != 0
      raise ::File::Error.from_errno("Error setting time on file", file: path)
    end
  end

  private def system_truncate(size) : Nil
    code = LibC.ftruncate(fd, size)
    if code != 0
      raise ::File::Error.from_errno("Error truncating file", file: path)
    end
  end

  # Attempts to clone (reflink / copy-on-write) the regular file open as *src*
  # to the path *dst*, returning `true` when the whole copy was performed this
  # way. Returns `false` when cloning is not applicable — the destination
  # already exists, the filesystem has no copy-on-write support, or the two
  # paths live on different filesystems — and the caller must fall back to a
  # regular copy. A clone copies the source's data and metadata (including its
  # permission bits) without copying any data blocks.
  def self.copy_clone?(src : ::File, dst : String) : Bool
    {% if flag?(:darwin) %}
      # `fclonefileat` only creates a new file: it fails with EEXIST when *dst*
      # exists, ENOTSUP on a filesystem without clone support (e.g. not APFS),
      # and EXDEV across filesystems. In all of these the caller falls back.
      LibC.fclonefileat(src.fd, LibC::AT_FDCWD, dst.check_no_null_byte, 0) == 0
    {% else %}
      false
    {% end %}
  end

  # Copies the contents of the regular file open as *src* to the regular file
  # open as *dst* using an in-kernel copy, returning `true` when the copy was
  # fully performed. Returns `false` when no in-kernel copy is available — and
  # nothing has been written yet, so the caller falls back to `IO.copy`. Raises
  # on an I/O error. Both descriptors are assumed to be at offset 0.
  def self.copy_data(src : ::File, dst : ::File) : Bool
    {% if flag?(:linux) && !flag?(:android) %}
      copy_file_range(src, dst)
    {% else %}
      false
    {% end %}
  end

  {% if flag?(:linux) && !flag?(:android) %}
    # `copy_file_range` support cache: 0 = not probed, 1 = unavailable,
    # 2 = available. Mirrors the strategy used by Rust's and Go's standard
    # libraries: probe once, then never call an unsupported syscall again.
    @@copy_file_range_support = Atomic(Int32).new(0)

    private def self.copy_file_range(src : ::File, dst : ::File) : Bool
      return false if @@copy_file_range_support.get == 1

      written = 0_i64
      # Every iteration ends in `return`, `raise` or `next`, so the loop never
      # falls through (its type is `NoReturn`).
      loop do
        # Cap each round at 1 GiB (avoids EOVERFLOW on huge files); null offsets
        # use and advance each descriptor's own file offset.
        ret = LibC.copy_file_range(src.fd, Pointer(Int64).null, dst.fd, Pointer(Int64).null, 0x4000_0000, 0)

        if ret > 0
          @@copy_file_range_support.compare_and_set(0, 2)
          written += ret.to_i64
        elsif ret == 0
          # A zero return is EOF once we have copied something. A zero on the
          # very first call is either an empty source or the pre-5.19 silent
          # failure on some virtual filesystems; fall back to a userspace copy.
          return written > 0
        else
          errno = Errno.value
          next if errno == Errno::EINTR

          # Once any byte has been written the offsets have advanced, so we can
          # no longer fall back to a fresh userspace copy — surface the error.
          if written > 0
            raise ::File::Error.from_os_error("Error copying file", errno, file: src.path, other: dst.path)
          end

          case errno
          when Errno::EOVERFLOW
            # The syscall works, the request was just too large; fall back.
            return false
          when Errno::ENOSYS, Errno::EOPNOTSUPP, Errno::EPERM
            # Either the syscall is missing or a seccomp filter blocks it; probe
            # with invalid descriptors to tell the two apart before giving up.
            @@copy_file_range_support.set(probe_copy_file_range) if @@copy_file_range_support.get == 0
            return false
          when Errno::EXDEV, Errno::EINVAL, Errno::EBADF, Errno::EIO
            # The syscall works, just not for this pair of files (cross-device,
            # a non-regular file, an O_APPEND destination, ...); fall back.
            @@copy_file_range_support.set(2) if @@copy_file_range_support.get == 0
            return false
          else
            raise ::File::Error.from_os_error("Error copying file", errno, file: src.path, other: dst.path)
          end
        end
      end
    end

    # Probes `copy_file_range` with invalid descriptors: a real syscall rejects
    # them with EBADF, while a missing or seccomp-blocked one fails with
    # ENOSYS/EPERM. Returns 2 (available) or 1 (unavailable).
    private def self.probe_copy_file_range : Int32
      LibC.copy_file_range(-1, Pointer(Int64).null, -1, Pointer(Int64).null, 1, 0)
      Errno.value == Errno::EBADF ? 2 : 1
    end
  {% end %}
end
