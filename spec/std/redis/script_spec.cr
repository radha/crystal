require "spec"
require "../../support/redis"

describe Redis::Script do
  it "computes the SHA1 of the source locally" do
    Redis::Script.new("").sha.should eq("da39a3ee5e6b4b0d3255bfef95601890afd80709")
    s = Redis::Script.new("return 1")
    s.source.should eq("return 1")
    s.sha.should eq(Digest::SHA1.hexdigest("return 1"))
    s.sha.size.should eq(40)
  end
end

describe Redis::AbortedError do
  it "is a Redis::Error with a default message" do
    err = Redis::AbortedError.new
    err.should be_a(Redis::Error)
    err.message.should eq("transaction aborted: a watched key changed")
    Redis::AbortedError.new("custom").message.should eq("custom")
  end
end
