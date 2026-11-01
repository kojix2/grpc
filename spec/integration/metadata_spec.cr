require "../spec_helper"
require "../support/integration_helpers"
require "../support/interceptors"

describe "GRPC metadata" do
  it "client metadata arrives at the server" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle MetaEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      ctx = GRPC::ClientContext.new(metadata: {"x-test-header" => "hello-world"})
      response = channel.unary_call("test.MetaEcho", "GetMeta",
        TestProto.encode_string("x-test-header"), ctx)
      response.status.ok?.should be_true
      TestProto.decode_string(response.raw).should eq("hello-world")
    ensure
      channel.close
      server.stop
    end
  end

  it "sends initial metadata accumulated on ServerContext" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle MetaEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      response = channel.unary_call("test.MetaEcho", "InitialMetadata", Bytes.empty)
      response.status.ok?.should be_true
      response.initial_metadata.get("x-context-initial").should eq("present")
    ensure
      channel.close
      server.stop
    end
  end

  it "sends initial metadata returned by unary and streaming interceptors" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle EchoService.new
    server.handle StreamingEchoService.new
    server.intercept InitialMetadataServerInterceptor.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      unary = channel.unary_call("test.Echo", "Echo", TestProto.encode_string("meta"))
      unary.initial_metadata.get("x-interceptor-initial").should eq("unary")

      stream = channel.open_server_stream("test.StreamingEcho", "ServerStream",
        TestProto.encode_string("meta"))
      stream.to_a.size.should eq(3)
      stream.headers.get("x-interceptor-initial").should eq("stream")
    ensure
      channel.close
      server.stop
    end
  end

  it "metadata injected by a client interceptor arrives at the server" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle MetaEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}",
      interceptors: [MutatingClientInterceptor.new] of GRPC::ClientInterceptor)

    begin
      # MutatingClientInterceptor injects x-from-interceptor: 1 into the context
      response = channel.unary_call("test.MetaEcho", "GetMeta",
        TestProto.encode_string("x-from-interceptor"))
      response.status.ok?.should be_true
      TestProto.decode_string(response.raw).should eq("1")
    ensure
      channel.close
      server.stop
    end
  end
end
