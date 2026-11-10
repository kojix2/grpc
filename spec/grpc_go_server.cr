require "./spec_helper"
require "./support/integration_helpers"

private class GoServerFirstService < GRPC::Service
  def service_full_name : String
    "test.GoServerFirst"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {request_body, GRPC::Status.ok}
  end

  def bidi_streaming?(method : String) : Bool
    method == "Bidi"
  end

  def dispatch_bidi_stream(method : String, requests : GRPC::RawRequestStream,
                           ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    # google.protobuf.BytesValue { value: 42 }
    writer.send_raw(Bytes[10, 1, 42])
    requests.each { |body| writer.send_raw(body) }
    GRPC::Status.ok
  end
end

describe "grpc-go client / Crystal server" do
  it "receives a server-first stream and reuses the connection after rejection" do
    port = find_free_port
    connections = [] of Int32
    factory = ->(io : IO, services : Hash(String, GRPC::Service), interceptors : Array(GRPC::ServerInterceptor), peer : String, tls : OpenSSL::SSL::Socket::Server?) {
      connections << 1
      GRPC::Transport::Http2ServerConnection.new(io, services, interceptors, peer, tls,
        GRPC::ReceiveLimits.new, GRPC::SendLimits.new, true).as(GRPC::Transport::ServerTransport)
    }
    server = GRPC::Server.new(transport_factory: factory)
    server.handle(GoServerFirstService.new)
    server.bind("127.0.0.1:#{port}")
    server.start
    output = IO::Memory.new
    errors = IO::Memory.new
    begin
      status = Process.run("./bin/grpc-go-peer", ["-client-target", "127.0.0.1:#{port}"], output: output, error: errors)
      status.success?.should be_true, errors.to_s
      output.to_s.should contain("grpc-go client passed")
      connections.size.should eq(1)
    ensure
      server.stop
    end
  end
end
