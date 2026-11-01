require "../spec_helper"

class DebugService < GRPC::Service
  SERVICE_FULL_NAME = "debug.Test"

  def service_full_name : String
    SERVICE_FULL_NAME
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    case method
    when "Ping"
      {"\x00pong".to_slice, GRPC::Status.ok}
    else
      {Bytes.empty, GRPC::Status.unimplemented("unknown")}
    end
  end
end

describe "binary unary response" do
  it "preserves a leading zero byte in the response body" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close

    grpc_server = GRPC::Server.new
    grpc_server.handle DebugService.new
    grpc_server.bind("127.0.0.1:#{port}")
    grpc_server.start

    sleep 10.milliseconds

    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    response = channel.unary_call("debug.Test", "Ping", Bytes.empty)

    response.status.ok?.should be_true
    response.raw.should eq("\x00pong".to_slice)
  ensure
    channel.try &.close
    grpc_server.try &.stop
  end
end
