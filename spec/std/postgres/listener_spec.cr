require "../../support/postgres"

private def with_client(&)
  db = Postgres::Client.new(PostgresSpec::URL, pool_size: 2)
  begin
    yield db
  ensure
    db.close
  end
end

describe Postgres::Listener do
  pending_postgres "receives notifications on the channels it listens on" do
    with_client do |db|
      listener = db.listener
      begin
        listener.listen("spec_a", "spec b \"quoted\"")
        listener.channels.should eq(["spec_a", "spec b \"quoted\""])
        db.notify("spec_a", "one")
        db.notify("spec b \"quoted\"", "two")
        db.notify("spec_other", "ignored")
        first = listener.receive
        {first.channel, first.payload}.should eq({"spec_a", "one"})
        first.pid.should be > 0
        listener.receive.payload.should eq("two")
        listener.receive(50.milliseconds).should be_nil
        listener.unlisten("spec_a")
        db.notify("spec_a", "gone")
        listener.receive(50.milliseconds).should be_nil
        listener.unlisten
        listener.channels.should be_empty
      ensure
        listener.close
      end
      listener.closed?.should be_true
      listener.receive?.should be_nil
      expect_raises(Postgres::ConnectionError, /closed/) { listener.listen("x") }
    end
  end

  pending_postgres "delivers notifications sent in a transaction at commit" do
    with_client do |db|
      listener = db.listener
      begin
        listener.listen("spec_tx")
        db.transaction do |tx|
          tx.notify("spec_tx", "in tx")
          listener.receive(50.milliseconds).should be_nil
        end
        listener.receive(1.second).try(&.payload).should eq("in tx")
      ensure
        listener.close
      end
    end
  end

  pending_postgres "reconnects, listens again and calls the hooks after the server drops it" do
    with_client do |db|
      listener = db.listener
      dropped = Channel(Exception).new(1)
      back = Channel(Nil).new(1)
      listener.on_disconnect = ->(ex : Exception) { dropped.send(ex); nil }
      listener.on_reconnect = -> { back.send(nil); nil }
      begin
        listener.listen("spec_re")
        pids = db.query_all("select pid from pg_stat_activity where query like 'LISTEN%spec_re%'", as: Int32)
        pids.size.should eq(1)
        db.exec("select pg_terminate_backend($1)", pids[0])
        select
        when dropped.receive
        when timeout(5.seconds) then fail "no disconnect"
        end
        select
        when back.receive
        when timeout(5.seconds) then fail "no reconnect"
        end
        listener.connected?.should be_true
        db.notify("spec_re", "after")
        listener.receive(2.seconds).try(&.payload).should eq("after")
      ensure
        listener.close
      end
    end
  end

  pending_postgres "closes itself instead of reconnecting with reconnect: false" do
    with_client do |db|
      listener = db.listener(reconnect: false)
      listener.listen("spec_nr")
      pid = db.query_one("select pid from pg_stat_activity where query like 'LISTEN%spec_nr%'", as: Int32)
      db.exec("select pg_terminate_backend($1)", pid)
      listener.receive?.should be_nil
      listener.closed?.should be_true
      listener.error.should be_a(Postgres::Error)
    end
  end

  pending_postgres "refuses control calls from its own hooks" do
    with_client do |db|
      listener = db.listener
      result = Channel(Exception?).new(1)
      listener.on_disconnect = ->(ex : Exception) do
        begin
          listener.listen("x")
          result.send(nil)
        rescue e
          result.send(e)
        end
        nil
      end
      begin
        listener.listen("spec_hook")
        pid = db.query_one("select pid from pg_stat_activity where query like 'LISTEN%spec_hook%'", as: Int32)
        db.exec("select pg_terminate_backend($1)", pid)
        result.receive.should be_a(ArgumentError)
      ensure
        listener.close
      end
    end
  end

  pending_postgres "lets a plain connection handle notifications while it queries" do
    PostgresSpec.connect do |conn|
      got = [] of String
      conn.on_notification = ->(n : Postgres::Notification) { got << n.payload; nil }
      conn.exec("listen spec_plain")
      conn.notify("spec_plain", "self")
      conn.query_one("select 1", as: Int32)
      got.should eq(["self"])
    end
  end
end
