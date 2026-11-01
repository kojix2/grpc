require "../spec_helper"

describe GRPC::ClientContext do
  describe "metadata" do
    it "holds metadata from a hash" do
      ctx = GRPC::ClientContext.new(metadata: {"authorization" => "Bearer token"})
      ctx.metadata.get("authorization").should eq("Bearer token")
    end
  end

  describe "deadlines" do
    it "converts a span deadline to absolute time" do
      before = Time.utc
      ctx = GRPC::ClientContext.new(deadline: 5.seconds)
      after = Time.utc
      dl = ctx.deadline.as(Time)
      dl.should be >= (before + 5.seconds)
      dl.should be <= (after + 5.seconds)
    end

    it "returns nil remaining when no deadline" do
      ctx = GRPC::ClientContext.new
      ctx.remaining.should be_nil
    end

    it "reports remaining time before deadline" do
      ctx = GRPC::ClientContext.new(deadline: 10.seconds)
      ctx.remaining.should_not be_nil
    end

    it "does not add grpc-timeout when no deadline is set" do
      ctx = GRPC::ClientContext.new
      meta = ctx.effective_metadata
      meta.get("grpc-timeout").should be_nil
    end

    it "includes grpc-timeout in effective_metadata when deadline is set" do
      ctx = GRPC::ClientContext.new(deadline: 10.seconds)
      meta = ctx.effective_metadata
      meta.get("grpc-timeout").should_not be_nil
    end

    it "uses at most eight timeout digits and chooses a coarser unit when needed" do
      ctx = GRPC::ClientContext.new(deadline: 48.hours)
      value = ctx.effective_metadata.get("grpc-timeout")
      value.should_not be_nil
      value = value.as(String)
      value.should match(/\A[0-9]{1,8}[HMSmun]\z/)
      value.ends_with?('m').should be_false
    end

    it "rejects an already-expired deadline locally" do
      ctx = GRPC::ClientContext.new(deadline: Time.utc - 1.second)
      ex = expect_raises(GRPC::StatusError) { ctx.check_active! }
      ex.code.should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
    end

    it "does not open a transport for an already-expired call" do
      channel = GRPC::Channel.new("127.0.0.1:1")
      ctx = GRPC::ClientContext.new(deadline: Time.utc - 1.second)
      ex = expect_raises(GRPC::StatusError) do
        channel.unary_call("test.Service", "Method", Bytes.empty, ctx)
      end
      ex.code.should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
    end
  end
end

describe GRPC::ServerContext do
  describe "metadata" do
    it "exposes peer and metadata" do
      meta = GRPC::Metadata.new({"x-foo" => "bar"})
      ctx = GRPC::ServerContext.new("127.0.0.1:12345", meta)
      ctx.peer.should eq("127.0.0.1:12345")
      ctx.metadata.get("x-foo").should eq("bar")
    end
  end

  describe "deadlines" do
    it "reports no timeout when deadline is in the future" do
      ctx = GRPC::ServerContext.new("peer", GRPC::Metadata.new, Time.utc + 60.seconds)
      ctx.timed_out?.should be_false
    end

    it "detects deadline expiry" do
      ctx = GRPC::ServerContext.new("peer", GRPC::Metadata.new, Time.utc - 1.second)
      ctx.timed_out?.should be_true
    end
  end

  describe "cancellation" do
    it "tracks cancellation" do
      ctx = GRPC::ServerContext.new("peer")
      ctx.cancelled?.should be_false
      ctx.cancel
      ctx.cancelled?.should be_true
    end
  end
end
