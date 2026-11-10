require "../spec_helper"
require "../support/integration_helpers"

private class SendLimitService < GRPC::Service
  def service_full_name : String
    "test.SendLimit"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {request_body, GRPC::Status.ok}
  end

  def server_streaming?(method : String) : Bool
    method == "Large"
  end

  def dispatch_server_stream(method : String, request_body : Bytes,
                             ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    writer.send_raw(Bytes.new(64))
    GRPC::Status.ok
  end
end

describe "server send limits" do
  it "rejects an oversized streaming response while keeping the connection usable" do
    port = find_free_port
    limits = GRPC::SendLimits.new(max_message_size: 32, max_buffered_bytes: 64, max_connection_buffered_bytes: 128)
    server = GRPC::Server.new(send_limits: limits)
    server.handle(SendLimitService.new)
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    begin
      stream = channel.open_server_stream("test.SendLimit", "Large", Bytes.empty,
        GRPC::ClientContext.new(deadline: 3.seconds))
      stream.to_a.should be_empty
      stream.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      reply = channel.unary_call("test.SendLimit", "Echo", Bytes[7], GRPC::ClientContext.new(deadline: 3.seconds))
      reply.status.ok?.should be_true
      reply.raw.should eq(Bytes[7])
    ensure
      channel.close
      server.stop
    end
  end
end
