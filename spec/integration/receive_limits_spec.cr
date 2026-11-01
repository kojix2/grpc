require "../spec_helper"
require "../support/malformed_peer"

class ReceiveLimitService < GRPC::Service
  def service_full_name : String
    "test.ReceiveLimits"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {method == "Large" ? Bytes.new(4096, 42_u8) : request_body, GRPC::Status.ok}
  end

  def server_streaming?(method : String) : Bool
    method == "LargeStream" || method == "CompressedStream"
  end

  def client_streaming?(method : String) : Bool
    method == "Count"
  end

  def dispatch_server_stream(method : String, request_body : Bytes,
                             ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    if method == "CompressedStream"
      ctx.initial_metadata.add("grpc-encoding", "gzip")
      writer.send_frame_for_validation_spec(GRPC::Codec.encode(Bytes.new(4096, 42_u8), compress: true))
    else
      writer.send_raw(Bytes.new(4096, 42_u8))
    end
    GRPC::Status.ok
  end

  def dispatch_client_stream(method : String, requests : GRPC::RawRequestStream,
                             ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    count = 0
    requests.each { |_message| count += 1 }
    {count.to_s.to_slice, GRPC::Status.ok}
  end
end

# Production responses are uncompressed. This test peer also emits a valid gzip
# unary response so the real client's bounded decompression/status path is used.
class ReceiveLimitConnection < MalformedFrameConnection
  private def dispatch_unary(stream_id : Int32, method_name : String,
                             request_bytes : Bytes, ctx : GRPC::ServerContext,
                             service : GRPC::Service, encoding : String?) : Nil
    return super unless method_name == "CompressedUnary"
    ctx.initial_metadata.add("grpc-encoding", "gzip")
    send_stream_headers(stream_id, ctx.initial_metadata)
    send_stream_chunk(stream_id, GRPC::Codec.encode(Bytes.new(4096, 42_u8), compress: true))
    send_stream_trailers(stream_id, GRPC::Status.ok)
  end
end

private def with_receive_limits(server_limits : GRPC::ReceiveLimits = GRPC::ReceiveLimits.new,
                                client_limits : GRPC::ReceiveLimits = GRPC::ReceiveLimits.new,
                                compressed_peer : Bool = false, &)
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.port
  listener.close
  factory : GRPC::Server::ServerTransportFactory? = nil
  if compressed_peer
    factory = ->(io : IO, services : Hash(String, GRPC::Service), interceptors : Array(GRPC::ServerInterceptor), peer : String, tls : OpenSSL::SSL::Socket::Server?) {
      ReceiveLimitConnection.new(io, services, interceptors, peer, tls, server_limits).as(GRPC::Transport::ServerTransport)
    }
  end
  server = GRPC::Server.new(transport_factory: factory, receive_limits: server_limits)
  server.handle(ReceiveLimitService.new)
  server.bind("127.0.0.1:#{port}")
  server.start
  channel = GRPC::Channel.new("127.0.0.1:#{port}", endpoint_config: GRPC::EndpointConfig.new(receive_limits: client_limits))
  yield channel
ensure
  channel.try &.close
  server.try &.stop
end

private def check_connection_after_limit(channel : GRPC::Channel) : Nil
  reply = channel.unary_call("test.ReceiveLimits", "Echo", Bytes[7], GRPC::ClientContext.new(deadline: 3.seconds))
  reply.status.ok?.should be_true
  reply.raw.should eq(Bytes[7])
end

describe "HTTP/2 receive limits" do
  describe "client responses" do
    it "rejects a large unary response and keeps the connection usable" do
      with_receive_limits(client_limits: GRPC::ReceiveLimits.new(max_message_size: 32)) do |channel|
        reply = channel.unary_call("test.ReceiveLimits", "Large", Bytes.empty, GRPC::ClientContext.new(deadline: 3.seconds))
        reply.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
        check_connection_after_limit(channel)
      end
    end

    it "preserves RESOURCE_EXHAUSTED when unary gzip output exceeds the decoded limit" do
      limits = GRPC::ReceiveLimits.new(max_wire_size: 128, max_message_size: 32)
      with_receive_limits(client_limits: limits, compressed_peer: true) do |channel|
        reply = channel.unary_call("test.ReceiveLimits", "CompressedUnary", Bytes.empty, GRPC::ClientContext.new(deadline: 3.seconds))
        reply.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
        reply.status.message.should contain("decompressed")
        check_connection_after_limit(channel)
      end
    end

    {"LargeStream", "CompressedStream"}.each do |method|
      it "rejects an oversized #{method} response without losing the connection" do
        limits = GRPC::ReceiveLimits.new(max_wire_size: 128, max_message_size: 32)
        with_receive_limits(client_limits: limits, compressed_peer: true) do |channel|
          stream = channel.open_server_stream("test.ReceiveLimits", method, Bytes.empty, GRPC::ClientContext.new(deadline: 3.seconds))
          stream.each { |_message| fail "oversized response reached the application" }
          stream.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
          stream.status.message.should contain("decompressed") if method == "CompressedStream"
          check_connection_after_limit(channel)
        end
      end
    end
  end

  describe "server requests" do
    it "rejects a unary request larger than the HTTP/2 window before receiving its body" do
      with_receive_limits(server_limits: GRPC::ReceiveLimits.new(max_wire_size: 32)) do |channel|
        3.times do
          reply = channel.unary_call("test.ReceiveLimits", "Echo", Bytes.new(128 * 1024), GRPC::ClientContext.new(deadline: 3.seconds))
          reply.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
          check_connection_after_limit(channel)
        end
      end
    end

    it "rejects unary gzip expansion over the server's decoded size limit" do
      limits = GRPC::ReceiveLimits.new(max_wire_size: 128, max_message_size: 32)
      with_receive_limits(server_limits: limits) do |channel|
        ctx = GRPC::ClientContext.new(metadata: {"grpc-encoding" => "gzip"}, deadline: 3.seconds)
        reply = channel.unary_call("test.ReceiveLimits", "Echo", Bytes.new(4096, 42_u8), ctx)
        reply.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
        check_connection_after_limit(channel)
      end
    end

    {false, true}.each do |compressed|
      it "rejects oversized live client-stream requests with compression=#{compressed}" do
        limits = GRPC::ReceiveLimits.new(max_wire_size: 128, max_message_size: 32)
        with_receive_limits(server_limits: limits) do |channel|
          ctx = GRPC::ClientContext.new(metadata: {"grpc-encoding" => compressed ? "gzip" : "identity"}, deadline: 3.seconds)
          call = channel.open_client_stream_live("test.ReceiveLimits", "Count", ctx)
          call.send_raw(Bytes.new(4096, 42_u8))
          call.close_and_recv
          call.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
          call.cancel
          check_connection_after_limit(channel)
        end
      end
    end

    it "accepts exact limits in both directions" do
      limits = GRPC::ReceiveLimits.new(max_wire_size: 32, max_message_size: 32, max_buffered_bytes: 32)
      with_receive_limits(server_limits: limits, client_limits: limits) do |channel|
        payload = Bytes.new(32, 42_u8)
        reply = channel.unary_call("test.ReceiveLimits", "Echo", payload, GRPC::ClientContext.new(deadline: 3.seconds))
        reply.status.ok?.should be_true
        reply.raw.should eq(payload)
      end
    end
  end
end
