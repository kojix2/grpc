require "../spec_helper"
require "../support/integration_helpers"

private class NoGzipClient < GRPC::Transport::Http2ClientConnection
  private def build_request_headers(service : String, method : String, metadata : GRPC::Metadata) : Array(LibNghttp2::Nv)
    super.reject { |header| String.new(header.name, header.namelen) == "grpc-accept-encoding" }
  end
end

describe "GRPC compression integration" do
  it "compresses unary and streamed responses when the client accepts gzip" do
    port = find_free_port
    server = GRPC::Server.new(response_compression: true)
    server.handle(EchoService.new)
    server.handle(StreamingEchoService.new)
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    begin
      body = TestProto.encode_string("compressed reply")
      response = channel.unary_call("test.Echo", "Echo", body, GRPC::ClientContext.new(deadline: 3.seconds))
      fail response.status.to_s unless response.status.ok?
      response.status.ok?.should be_true
      response.initial_metadata.get("grpc-encoding").should eq("gzip")
      TestProto.decode_string(response.raw).should eq("echo:compressed reply")
      stream = channel.open_server_stream("test.StreamingEcho", "ServerStream", body,
        GRPC::ClientContext.new(deadline: 3.seconds))
      stream.to_a.map { |item| TestProto.decode_string(item) }.should eq(["0:compressed reply", "1:compressed reply", "2:compressed reply"])
      stream.headers.get("grpc-encoding").should eq("gzip")
      stream.status.ok?.should be_true
    ensure
      channel.close
      server.stop
    end
  end

  it "does not compress responses for a client that did not advertise gzip" do
    port = find_free_port
    server = GRPC::Server.new(response_compression: true)
    server.handle(EchoService.new)
    server.bind("127.0.0.1:#{port}")
    server.start
    connection = NoGzipClient.new("127.0.0.1", port)
    begin
      response = connection.unary_call("test.Echo", "Echo", TestProto.encode_string("plain"))
      response.status.ok?.should be_true
      response.initial_metadata.get("grpc-encoding").should be_nil
      TestProto.decode_string(response.raw).should eq("echo:plain")
    ensure
      connection.close
      server.stop
    end
  end

  it "handles a gzip-compressed request body" do
    port = find_free_port
    server = start_test_server(port)
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      raw = TestProto.encode_string("compressed")
      metadata = GRPC::Metadata.new
      metadata.add("grpc-encoding", "gzip")
      response = channel.unary_call("test.Echo", "Echo", raw, metadata)
      response.status.ok?.should be_true
      TestProto.decode_string(response.raw).should eq("echo:compressed")
      response.initial_metadata.get("grpc-accept-encoding").should eq("gzip")
    ensure
      channel.close
      server.stop
    end
  end
end
