require "../spec_helper"
require "../support/integration_helpers"
require "../support/protocol_peer"

private class ServerLifecycleConnection < GRPC::Transport::Http2ServerConnection
  def retained_stream_state : Int32
    @mutex.synchronize do
      @stream_headers_sent.size + @stream_terminated.size + @stream_boxes.size +
        @stream_contexts.size + @live_request_states.size + @deadline_watch_stops.size
    end
  end
end

private class ServerLifecycleService < GRPC::Service
  getter calls = 0
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)
  getter returned = Channel(Nil).new(1)

  def service_full_name : String
    "test.ServerLifecycle"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    @calls += 1
    if method == "Late"
      @entered.send(nil)
      @release.receive
      @returned.send(nil)
    end
    status = method == "Error" ? GRPC::Status.invalid_argument("日本語 é α % + space") : GRPC::Status.ok
    {request_body, status}
  end
end

# Send a wire timeout without installing the client's own deadline watcher.
private class HeaderDeadlineClient < GRPC::Transport::Http2ClientConnection
  private def build_request_headers(service : String, method : String, metadata : GRPC::Metadata) : Array(LibNghttp2::Nv)
    headers = super
    headers << make_nv("grpc-timeout", "20m")
    headers
  end
end

def with_server_lifecycle(&)
  connections = [] of ServerLifecycleConnection
  factory = ->(io : IO, services : Hash(String, GRPC::Service), interceptors : Array(GRPC::ServerInterceptor), peer : String, tls : OpenSSL::SSL::Socket::Server?) {
    connection = ServerLifecycleConnection.new(io, services, interceptors, peer, tls)
    connections << connection
    connection.as(GRPC::Transport::ServerTransport)
  }
  service = ServerLifecycleService.new
  server = GRPC::Server.new(transport_factory: factory)
  server.handle(service)
  port = find_free_port
  server.bind("127.0.0.1:#{port}")
  server.start
  begin
    yield port, service, connections
  ensure
    server.stop
  end
end

describe "GRPC server stream lifecycle" do
  it "round-trips a UTF-8 error message with percent signs, plus signs and spaces" do
    with_server_lifecycle do |port, _service, _connections|
      channel = GRPC::Channel.new("127.0.0.1:#{port}")
      begin
        response = channel.unary_call("test.ServerLifecycle", "Error", Bytes.empty)
        response.status.message.should eq("日本語 é α % + space")
      ensure
        channel.close
      end
    end
  end

  it "releases per-stream state after repeated calls on a long-lived connection" do
    with_server_lifecycle do |port, service, connections|
      channel = GRPC::Channel.new("127.0.0.1:#{port}")
      begin
        100.times { channel.unary_call("test.ServerLifecycle", "Echo", Bytes.empty).status.ok?.should be_true }
        wait_for_protocol_state { connections.first.retained_stream_state == 0 }
        connections.size.should eq(1)
        service.calls.should eq(100)
      ensure
        channel.close
      end
    end
  end

  it "starts the server deadline at HEADERS and expires before a delayed request body" do
    with_server_lifecycle do |port, service, connections|
      client = HeaderDeadlineClient.new("127.0.0.1", port)
      begin
        call = client.open_bidi_stream_live("test.ServerLifecycle", "Echo")
        wait_for_protocol_state { !call.final_status.nil? }
        call.final_status.try(&.code).should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
        service.calls.should eq(0)
        wait_for_protocol_state { connections.first.retained_stream_state == 0 }
        expect_raises(GRPC::SendClosedError) { call.send_raw(Bytes[42]) }
      ensure
        client.close
      end
    end
  end

  it "ignores a handler returning after its stream closes and still serves subsequent calls" do
    with_server_lifecycle do |port, service, connections|
      channel = GRPC::Channel.new("127.0.0.1:#{port}")
      begin
        call = channel.open_bidi_stream_live("test.ServerLifecycle", "Late")
        call.send_raw(Bytes[1])
        call.close_send
        service.entered.receive
        call.cancel
        wait_for_protocol_state { connections.first.retained_stream_state == 0 }
        service.release.send(nil)
        service.returned.receive
        response = channel.unary_call("test.ServerLifecycle", "Echo", Bytes.empty)
        response.status.ok?.should be_true
        wait_for_protocol_state { connections.first.retained_stream_state == 0 }
      ensure
        channel.close
      end
    end
  end
end
