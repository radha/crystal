# A bounded, fiber-safe pool of connections (or any other resource that
# responds to `#close` and `#closed?`).
#
# Connections are opened lazily by the factory block, up to `size` at once.
# `checkout` waits up to `checkout_timeout` for one to come back before
# raising `Pool::TimeoutError`. Idle connections are reused in FIFO order:
# the connection that has been idle the longest is handed out first, which
# keeps every connection warm rather than letting some go stale.
#
# A connection that is closed when it is checked in is dropped, and so is
# one found closed while idle; the next `checkout` opens a fresh one. When a
# *health_check* is given, a connection that has been idle for at least
# `health_check_after` is checked before it is handed out; one that fails
# the check (returns `false` or raises) is closed and replaced.
#
# ```
# require "pool"
# require "socket"
#
# pool = Pool(TCPSocket).new(size: 4, checkout_timeout: 2.seconds) do
#   TCPSocket.new("localhost", 6379)
# end
#
# pool.checkout do |socket|
#   socket << "PING\r\n"
#   socket.gets
# end
#
# pool.close
# ```
class Pool(T)
  # Base class of the errors raised by `Pool`.
  class Error < Exception
  end

  # Raised by `checkout` when no connection became available within
  # `checkout_timeout`.
  class TimeoutError < Error
  end

  # Raised by `checkout` when the pool is closed.
  class ClosedError < Error
  end

  # Returns the maximum number of connections open at once.
  getter size : Int32

  # Returns how long `checkout` waits for a connection.
  getter checkout_timeout : Time::Span

  # Returns how long a connection must have been idle before the health
  # check runs on it at checkout.
  getter health_check_after : Time::Span

  @mutex = Mutex.new
  @idle = Deque({T, Time::Instant}).new
  @in_use = 0
  @closed = false
  # Permits not held by anyone. A checkout takes one under the mutex; only
  # when none is free does it wait on `@handoff`, so an uncontended
  # checkout neither touches a channel nor allocates.
  @available : Int32
  # Fibers waiting on `@handoff` that no permit has been sent for yet.
  @waiting = 0
  # Permits handed from `checkin` to waiting fibers. Its capacity is `size`,
  # so sending under the mutex never blocks.
  @handoff : Channel(Nil)

  # Creates an empty pool whose connections are opened by the block. *T*
  # must respond to `#close` and `#closed?`.
  #
  # When *health_check* is given, it is called at checkout on a connection
  # that has been idle for at least *health_check_after*; a connection for
  # which it returns `false` or raises is closed and replaced.
  #
  # Raises `ArgumentError` if *size* is not positive.
  def initialize(*, @size : Int32 = 8, @checkout_timeout : Time::Span = 5.seconds,
                 @health_check : Proc(T, Bool)? = nil, @health_check_after : Time::Span = 1.second,
                 &@factory : -> T)
    raise ArgumentError.new("pool size must be positive, got #{@size}") unless @size > 0
    @available = @size
    @handoff = Channel(Nil).new(@size)
  end

  # Returns the number of open connections waiting in the pool.
  def idle : Int32
    @mutex.synchronize { @idle.size }
  end

  # Returns the number of connections currently checked out.
  def in_use : Int32
    @mutex.synchronize { @in_use }
  end

  # Returns whether `close` has been called. This is an advisory snapshot:
  # it is read without the lock, so it can be stale by the time the caller
  # acts on it under a concurrent `close`.
  def closed? : Bool
    @closed
  end

  # Takes a connection, reusing an idle one or opening one with the factory
  # if none is idle and fewer than `size` are out.
  #
  # Raises `TimeoutError` after `checkout_timeout`, `ClosedError` if the
  # pool is closed. An exception raised by the factory propagates
  # unchanged. Hand the connection back with `checkin`; the block form
  # does that for you.
  def checkout : T
    # Unlocked pre-check to fail fast; the checks under the mutex count.
    raise ClosedError.new("pool is closed") if @closed
    entry = @mutex.synchronize do
      raise ClosedError.new("pool is closed") if @closed
      if @available > 0
        @available -= 1
        @in_use += 1
        {true, next_idle_unlocked}
      else
        @waiting += 1
        {false, nil}
      end
    end
    got, idle = entry
    unless got
      wait_for_permit
      idle = @mutex.synchronize do
        if @closed
          release_permit_unlocked
          raise ClosedError.new("pool is closed")
        end
        @in_use += 1
        next_idle_unlocked
      end
    end
    begin
      acquire(idle)
    rescue ex
      @mutex.synchronize do
        @in_use -= 1
        release_permit_unlocked
      end
      raise ex
    end
  end

  # Waits for `checkin` to hand this fiber a permit. On timeout the fiber
  # stops being counted as waiting, unless a permit was already sent for
  # it, in which case it takes that one instead of leaking it.
  private def wait_for_permit : Nil
    select
    when @handoff.receive
      return
    when timeout(@checkout_timeout)
    end
    served = @mutex.synchronize do
      if @waiting > 0
        @waiting -= 1
        false
      else
        true
      end
    end
    # Every waiter still counted in `@waiting` has no permit in flight, so
    # when the count is zero one of the permits in `@handoff` is ours (and
    # it is already there: they are sent under the mutex).
    if served
      @handoff.receive
      return
    end
    raise TimeoutError.new("no connection available after #{@checkout_timeout}")
  end

  # Under `@mutex`: hands the permit to a waiting fiber, or puts it back.
  private def release_permit_unlocked : Nil
    if @waiting > 0
      @waiting -= 1
      @handoff.send(nil)
    else
      @available += 1
    end
  end

  # Returns *connection* to the pool. A closed connection is dropped; if
  # the pool is closed the connection is closed too. Checking in a
  # connection twice, or one this pool never handed out, is not detected.
  def checkin(connection : T) : Nil
    close_it = @mutex.synchronize do
      @in_use -= 1
      discard = @closed || connection.closed?
      @idle.push({connection, Time.instant}) unless discard
      release_permit_unlocked
      discard
    end
    connection.close if close_it
  end

  # Checks a connection out, yields it and checks it in again, whatever
  # the block does, returning the block's value.
  #
  # An exception raised by the block does not discard the connection: if
  # the failure left it unusable, `close` it before leaving the block and
  # the pool drops it on checkin.
  def checkout(& : T -> R) : R forall R
    connection = checkout
    begin
      yield connection
    ensure
      checkin(connection)
    end
  end

  # Closes every idle connection and marks the pool closed; connections in
  # use are closed when they are checked in. Idempotent.
  def close : Nil
    idle = @mutex.synchronize do
      @closed = true
      drained = @idle.map(&.[0])
      @idle.clear
      drained
    end
    idle.each(&.close)
  end

  # Hands out *entry* (taken under the mutex together with the permit) or
  # the next healthy idle connection, or opens one. The caller holds a
  # permit and has counted the connection in `@in_use`.
  private def acquire(entry : {T, Time::Instant}?) : T
    while entry
      connection, since = entry
      return connection unless health_check = @health_check
      return connection if Time.instant - since < @health_check_after
      # Runs outside the mutex: a check may do I/O.
      return connection if healthy?(health_check, connection)
      begin
        connection.close
      rescue
      end
      entry = next_idle
    end
    @factory.call
  end

  # Pops the longest-idle connection, skipping any that were closed while
  # idle (they are useless).
  private def next_idle : {T, Time::Instant}?
    @mutex.synchronize { next_idle_unlocked }
  end

  # Under `@mutex`: the oldest idle connection that is not closed.
  private def next_idle_unlocked : {T, Time::Instant}?
    while entry = @idle.shift?
      return entry unless entry[0].closed?
    end
  end

  private def healthy?(health_check : Proc(T, Bool), connection : T) : Bool
    health_check.call(connection)
  rescue Exception
    false
  end
end
