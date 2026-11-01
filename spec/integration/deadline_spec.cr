require "../spec_helper"
require "../support/integration_helpers"

describe "GRPC deadline" do
  it "grpc-timeout sent by client is received and parsed as a deadline on the server" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle MetaEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      ctx = GRPC::ClientContext.new(deadline: 30.seconds)
      response = channel.unary_call("test.MetaEcho", "HasDeadline", Bytes.empty, ctx)
      response.status.ok?.should be_true
      TestProto.decode_string(response.raw).should eq("yes")
    ensure
      channel.close
      server.stop
    end
  end

  it "fails with DEADLINE_EXCEEDED when grpc-timeout is already expired at dispatch" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle MetaEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      meta = GRPC::Metadata.new
      meta.add("grpc-timeout", "0m")
      response = channel.unary_call("test.MetaEcho", "HasDeadline", Bytes.empty, meta)
      response.status.ok?.should be_false
      response.status.code.should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
    ensure
      channel.close
      server.stop
    end
  end

  it "fails with INVALID_ARGUMENT when grpc-timeout format is malformed" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle MetaEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      meta = GRPC::Metadata.new
      meta.add("grpc-timeout", "oops")
      response = channel.unary_call("test.MetaEcho", "HasDeadline", Bytes.empty, meta)
      response.status.ok?.should be_false
      response.status.code.should eq(GRPC::StatusCode::INVALID_ARGUMENT)
    ensure
      channel.close
      server.stop
    end
  end

  it "rejects grpc-timeout values longer than eight digits" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle MetaEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      meta = GRPC::Metadata.new
      meta.add("grpc-timeout", "123456789m")
      response = channel.unary_call("test.MetaEcho", "HasDeadline", Bytes.empty, meta)
      response.status.code.should eq(GRPC::StatusCode::INVALID_ARGUMENT)
    ensure
      channel.close
      server.stop
    end
  end

  it "terminates a slow unary handler when deadline is exceeded mid-flight" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle DeadlineProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      ctx = GRPC::ClientContext.new(deadline: 30.milliseconds)
      response = channel.unary_call("test.DeadlineProbe", "SlowUnary", Bytes.empty, ctx)
      response.status.ok?.should be_false
      response.status.code.should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
    ensure
      channel.close
      server.stop
    end
  end

  it "terminates a running server-stream handler on deadline expiry" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle DeadlineProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      ctx = GRPC::ClientContext.new(deadline: 40.milliseconds)
      stream = channel.open_server_stream("test.DeadlineProbe", "SlowServerStream", Bytes.empty, ctx)
      started = Time.instant
      stream.each { |_bytes| }
      elapsed = Time.instant - started
      elapsed.should be < 1.second

      unless stream.status.ok?
        stream.status.code.should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
      end
    ensure
      channel.close
      server.stop
    end
  end
end
