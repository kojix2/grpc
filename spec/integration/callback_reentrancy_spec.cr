require "../spec_helper"
require "../support/integration_helpers"

private class CallbackAuditConnection < GRPC::Transport::Http2ServerConnection
  getter sends_inside_callback = 0
  @inside_callback = false

  def on_frame_recv_cb(frame : Void*) : Nil
    @inside_callback = true
    super
  ensure
    @inside_callback = false
  end

  def on_data_chunk_cb(stream_id : Int32, data : UInt8*, len : LibC::SizeT) : Nil
    @inside_callback = true
    super
  ensure
    @inside_callback = false
  end

  protected def session_mem_send(data_ptr : UInt8**) : LibC::SSizeT
    @sends_inside_callback += 1 if @inside_callback
    super
  end
end

describe "server callback reentrancy" do
  it "rejects headers and oversized data without reentering nghttp2 and reuses the connection" do
    port = find_free_port
    connections = [] of CallbackAuditConnection
    limits = GRPC::ReceiveLimits.new(max_wire_size: 32)
    factory = ->(io : IO, services : Hash(String, GRPC::Service), interceptors : Array(GRPC::ServerInterceptor), peer : String, tls : OpenSSL::SSL::Socket::Server?) {
      connection = CallbackAuditConnection.new(io, services, interceptors, peer, tls, limits)
      connections << connection
      connection.as(GRPC::Transport::ServerTransport)
    }
    server = GRPC::Server.new(transport_factory: factory)
    server.handle(EchoService.new)
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    begin
      ctx = -> { GRPC::ClientContext.new(deadline: 3.seconds) }
      rejected = channel.unary_call("missing.Service", "Echo", Bytes.empty, ctx.call)
      rejected.status.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
      oversized = channel.unary_call("test.Echo", "Echo", Bytes.new(128), ctx.call)
      oversized.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      accepted = channel.unary_call("test.Echo", "Echo", TestProto.encode_string("ok"), ctx.call)
      accepted.status.ok?.should be_true
      TestProto.decode_string(accepted.raw).should eq("echo:ok")
      connections.size.should eq(1)
      connections.first.sends_inside_callback.should eq(0)
    ensure
      channel.close
      server.stop
    end
  end
end
