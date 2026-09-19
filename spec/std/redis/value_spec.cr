require "spec"
require "redis"

describe Redis::BigNumber do
  it "compares and hashes by digits" do
    a = Redis::BigNumber.new("-3492890328409238509324850943850943825024385")
    b = Redis::BigNumber.new("-3492890328409238509324850943850943825024385")
    a.should eq(b)
    a.hash.should eq(b.hash)
    a.to_s.should eq("-3492890328409238509324850943850943825024385")
  end
end

describe Redis::CommandError do
  it "extracts the upper-case code" do
    Redis::CommandError.new("WRONGTYPE Operation against a key holding the wrong kind of value").code.should eq("WRONGTYPE")
    Redis::CommandError.new("ERR unknown command 'HELLO'").code.should eq("ERR")
    Redis::CommandError.new("NOPROTO").code.should eq("NOPROTO")
    Redis::CommandError.new("MOVED 3999 127.0.0.1:6381").code.should eq("MOVED")
    Redis::CommandError.new("lower case message").code.should eq("")
  end

  it "is a Redis::Error and a Redis::Value" do
    err = Redis::CommandError.new("ERR x")
    err.should be_a(Redis::Error)
    val : Redis::Value = err
    val.should be_a(Redis::CommandError)
    val.should eq(err)
  end
end

describe Redis::Value do
  it "admits every RESP3 shape" do
    v = [nil, true, 1_i64, 1.5, "s", Redis::BigNumber.new("1"), Set(Redis::Value){1_i64},
         {"k" => "v"} of Redis::Value => Redis::Value] of Redis::Value
    v.size.should eq(8)
  end
end
