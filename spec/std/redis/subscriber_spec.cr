require "spec"
require "../../support/redis"

# A fake pub/sub server for one protocol. Confirms every SUBSCRIBE-family
# command frame by frame (after `confirm_delay`, or never when
# `swallow_control` is set), answers PING in subscribed-mode shape, and
# lets the spec inject frames on the newest connection.
private class PubSubServer
  # Commands per accepted connection, in order, handshake excluded. (A
  # `protocol: 2` subscriber sends no HELLO at all, so connections are
  # tracked by socket, not by handshake.)
  getter seen = [] of Array(Array(String))
  property confirm_delay : Time::Span? = nil
  property swallow_control = false
  @sockets = [] of IO
  @protocol : Int32

  def initialize(@protocol : Int32)
  end

  def connections : Int32
    @seen.size
  end

  # Commands seen on the *n*th connection (1-based).
  def commands_on(n : Int32) : Array(Array(String))
    @seen[n - 1]
  end

  def server
    RedisSpec::FakeServer.new do |io|
      mine = [] of Array(String)
      @seen << mine
      @sockets << io
      # Per-connection subscription state, tracked like a real server so
      # that a bare UNSUBSCRIBE/PUNSUBSCRIBE can answer with one frame per
      # channel or pattern actually subscribed (counting down to 0), and a
      # single null-channel frame only when nothing is subscribed.
      channels = [] of String
      patterns = [] of String
      while cmd = RedisSpec::FakeServer.read_command(io)
        mine << cmd unless cmd[0] == "HELLO"
        case cmd[0]
        when "HELLO"
          io << (@protocol == 3 ? RedisSpec::HELLO_REPLY : "-ERR unknown command 'HELLO'\r\n")
        when "SUBSCRIBE", "PSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE"
          next if @swallow_control
          if delay = @confirm_delay
            sleep delay
          end
          kind = cmd[0].downcase
          names = cmd[1..]
          set = (kind == "subscribe" || kind == "unsubscribe") ? channels : patterns
          case kind
          when "subscribe", "psubscribe"
            names.each do |name|
              set << name unless set.includes?(name)
              io << RedisSpec.pubsub_frame(@protocol, kind, name, set.size)
            end
          else
            # Bare form: unsubscribe from everything currently tracked, in
            # insertion order, one frame per channel/pattern; a single
            # null-channel frame if nothing was subscribed. Named form:
            # only the given names.
            targets = names.empty? ? set.dup : names
            if targets.empty?
              io << RedisSpec.pubsub_frame(@protocol, kind, nil, 0)
            else
              targets.each do |name|
                set.delete(name)
                io << RedisSpec.pubsub_frame(@protocol, kind, name, set.size)
              end
            end
          end
        when "PING"
          io << (@protocol == 3 ? "+PONG\r\n" : RedisSpec.pubsub_frame(2, "pong", ""))
        else
          io << "+OK\r\n"
        end
        io.flush
      end
    end
  end

  def publish(channel : String, payload : String) : Nil
    inject RedisSpec.pubsub_frame(@protocol, "message", channel, payload)
  end

  def ppublish(pattern : String, channel : String, payload : String) : Nil
    inject RedisSpec.pubsub_frame(@protocol, "pmessage", pattern, channel, payload)
  end

  def inject(raw : String) : Nil
    io = @sockets.last
    io << raw
    io.flush
  end

  # Closes the newest client socket from the server side.
  def kill : Nil
    @sockets.last.close
  end
end

private def wait_until(timeout = 2.seconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "timed out waiting" if Time.instant > deadline
    sleep 5.milliseconds
  end
end

private def subscriber_specs(protocol : Int32)
  describe "Redis::Subscriber (RESP#{protocol})" do
    it "connects eagerly and subscribe waits for every confirmation" do
      fake = PubSubServer.new(protocol)
      fake.confirm_delay = 50.milliseconds
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      sub.connected?.should be_true
      sub.protocol.should eq(protocol)
      started = Time.instant
      sub.subscribe("a", "b")
      (Time.instant - started).should be >= 50.milliseconds
      sub.channels.should eq(["a", "b"])
      fake.commands_on(1).should eq([["SUBSCRIBE", "a", "b"]])
      sub.close
      sub.closed?.should be_true
      server.close
    end

    it "delivers messages and pattern messages in order" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      sub.subscribe("a")
      sub.psubscribe("log.*")
      sub.patterns.should eq(["log.*"])
      fake.publish("a", "hi")
      fake.ppublish("log.*", "log.x", "p")
      fake.publish("a", "again")
      sub.receive.should eq(Redis::Subscriber::Message.new("a", "hi"))
      sub.receive.should eq(Redis::Subscriber::Message.new("log.x", "p", "log.*"))
      m = sub.receive
      m.channel.should eq("a")
      m.payload.should eq("again")
      m.pattern.should be_nil
      sub.close
      server.close
    end

    it "unsubscribes by name and all at once" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      sub.subscribe("a", "b", "c")
      sub.unsubscribe("a")
      sub.channels.should eq(["b", "c"])
      sub.unsubscribe
      sub.channels.should be_empty
      sub.unsubscribe # nothing subscribed: server answers one nil frame
      sub.psubscribe("p.*")
      sub.punsubscribe
      sub.patterns.should be_empty
      fake.commands_on(1).should eq([
        ["SUBSCRIBE", "a", "b", "c"], ["UNSUBSCRIBE", "a"], ["UNSUBSCRIBE"], ["UNSUBSCRIBE"],
        ["PSUBSCRIBE", "p.*"], ["PUNSUBSCRIBE"],
      ])
      sub.close
      server.close
    end

    it "pings" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      sub.subscribe("a")
      sub.ping
      fake.commands_on(1).last.should eq(["PING"])
      sub.close
      server.close
    end

    it "a capacity of 1 still delivers everything in order" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, capacity: 1)
      sub.subscribe("a")
      20.times { |i| fake.publish("a", i.to_s) }
      got = [] of String
      20.times { got << sub.receive.payload }
      got.should eq((0...20).map(&.to_s))
      sub.close
      server.close
    end

    it "each iterates until close, and close drains buffered messages first" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, capacity: 8)
      sub.subscribe("a")
      fake.publish("a", "1")
      fake.publish("a", "2")
      sub.receive.payload.should eq("1")
      sub.ping # ordered after "2" on the wire; returns only once it's read
      sub.close
      sub.receive?.try(&.payload).should eq("2")
      sub.receive?.should be_nil
      expect_raises(Redis::ConnectionError, /closed/) { sub.receive }
      expect_raises(Redis::ConnectionError, /closed/) { sub.subscribe("b") }
      seen = [] of String
      sub.each { |m| seen << m.payload }
      seen.should be_empty
      server.close
    end

    it "rejects an empty subscribe" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      expect_raises(ArgumentError) { sub.subscribe }
      expect_raises(ArgumentError) { sub.psubscribe }
      sub.close
      server.close
    end

    it "with reconnect: false a drop closes the subscriber and reports the cause" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, reconnect: false)
      causes = [] of Exception
      sub.on_disconnect = ->(ex : Exception) { causes << ex; nil }
      sub.subscribe("a")
      fake.kill
      sub.receive?.should be_nil
      sub.closed?.should be_true
      sub.connected?.should be_false
      sub.error.should be_a(IO::Error)
      causes.size.should eq(1)
      expect_raises(Redis::ConnectionError) { sub.subscribe("b") }
      server.close
    end

    it "an unknown frame is a ProtocolError drop" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, reconnect: false)
      sub.subscribe("a")
      fake.inject(RedisSpec.pubsub_frame(protocol, "weird", "x"))
      sub.receive?.should be_nil
      sub.error.should be_a(Redis::ProtocolError)
      server.close
    end

    it "read_timeout bounds a control command the server never confirms" do
      fake = PubSubServer.new(protocol)
      fake.swallow_control = true
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, read_timeout: 100.milliseconds, reconnect: false)
      expect_raises(IO::TimeoutError) { sub.subscribe("a") }
      sub.channels.should eq(["a"])
      sub.receive?.should be_nil
      server.close
    end

    it "reconnects, resubscribes channels then patterns, and keeps delivering" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      disconnected = Channel(Exception).new(1)
      reconnected = Channel(Nil).new(1)
      sub.on_disconnect = ->(ex : Exception) { disconnected.send(ex); nil }
      sub.on_reconnect = -> { reconnected.send(nil); nil }
      sub.subscribe("a", "b")
      sub.psubscribe("log.*")
      fake.kill
      disconnected.receive.should be_a(IO::Error)
      sub.error.should be_a(IO::Error)
      reconnected.receive
      # The hook fires when the resubscribe has been sent, which can be
      # before the fake server has read it.
      wait_until { fake.connections == 2 && fake.commands_on(2).size == 2 }
      fake.commands_on(2).should eq([["SUBSCRIBE", "a", "b"], ["PSUBSCRIBE", "log.*"]])
      sub.connected?.should be_true
      sub.error.should be_nil
      sub.channels.should eq(["a", "b"])
      fake.publish("a", "after")
      sub.receive.payload.should eq("after")
      sub.ping
      sub.close
      server.close
    end

    it "records a subscribe made while disconnected and applies it on reconnect" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      disconnected = Channel(Nil).new(1)
      reconnected = Channel(Nil).new(1)
      sub.on_disconnect = ->(ex : Exception) { disconnected.send(nil); nil }
      sub.on_reconnect = -> { reconnected.send(nil); nil }
      sub.subscribe("a")
      fake.kill
      disconnected.receive
      sub.subscribe("late") # returns at once: recorded only
      sub.channels.should eq(["a", "late"])
      reconnected.receive
      wait_until { fake.connections == 2 && fake.commands_on(2).size >= 1 }
      fake.commands_on(2).first.should eq(["SUBSCRIBE", "a", "late"])
      sub.close
      server.close
    end

    it "keeps retrying with backoff while the server is down and close interrupts the wait" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, connect_timeout: 200.milliseconds)
      disconnected = Channel(Nil).new(1)
      sub.on_disconnect = ->(ex : Exception) { disconnected.send(nil); nil }
      sub.subscribe("a")
      server.close
      fake.kill
      disconnected.receive
      sleep 400.milliseconds # at least the 100 ms and 200 ms attempts have failed
      sub.connected?.should be_false
      sub.closed?.should be_false
      started = Time.instant
      sub.close
      (Time.instant - started).should be < 100.milliseconds
      sub.receive?.should be_nil
    end

    it "a hook that raises closes the subscriber" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      sub.on_disconnect = ->(ex : Exception) : Nil { raise "hook failed" }
      sub.subscribe("a")
      fake.kill
      sub.receive?.should be_nil
      sub.closed?.should be_true
      sub.error.try(&.message).should eq("hook failed")
      server.close
    end
  end
end

subscriber_specs(3)
subscriber_specs(2)
