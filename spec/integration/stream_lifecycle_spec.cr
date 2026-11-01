require "../spec_helper"
require "../support/integration_helpers"

describe "GRPC ServerStream status and trailers" do
  it "status is OK after a successful server-streaming RPC" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      req_bytes = TestProto.encode_string("hello")
      stream = channel.open_server_stream("test.StreamingEcho", "ServerStream", req_bytes)
      messages = [] of String
      stream.each { |bytes| messages << TestProto.decode_string(bytes) }
      stream.status.ok?.should be_true
      messages.size.should eq(3)
    ensure
      channel.close
      server.stop
    end
  end

  it "status reflects a server-side error in a server-streaming RPC" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      stream = channel.open_server_stream("test.StreamingEcho", "ErrorStream", Bytes.empty)
      stream.each { }
      stream.status.ok?.should be_false
      stream.status.code.should eq(GRPC::StatusCode::INTERNAL)
    ensure
      channel.close
      server.stop
    end
  end

  it "cancel closes the stream early without raising" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      req_bytes = TestProto.encode_string("hello")
      stream = channel.open_server_stream("test.StreamingEcho", "ServerStream", req_bytes)
      # Cancel immediately — should not raise, iteration should stop.
      stream.cancel
      # Draining after cancel is safe (channel is closed, receive? returns nil).
      stream.each { }
    ensure
      channel.close
      server.stop
    end
  end
end

describe "GRPC stream status wiring" do
  it "ClientStream#status is ok after close_and_recv succeeds" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      raw = channel.open_client_stream_live("test.StreamingEcho", "ClientStream")
      raw.send_raw(TestProto.encode_string("x"))
      raw.close_and_recv
      raw.status.ok?.should be_true
      raw.status.code.should eq(GRPC::StatusCode::OK)
    ensure
      channel.close
      server.stop
    end
  end

  it "RawBidiCall#status is ok after each completes" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle FullDuplexEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      raw = channel.open_bidi_stream_live("test.FullDuplexEcho", "EchoStream")
      raw.send_raw(TestProto.encode_string("ping"))
      raw.close_send
      raw.each { }
      raw.status.ok?.should be_true
      raw.status.code.should eq(GRPC::StatusCode::OK)
    ensure
      channel.close
      server.stop
    end
  end
end
