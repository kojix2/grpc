require "./spec_helper"

class StreamingRegressionService < GRPC::Service
  def service_full_name : String
    "test.StreamingRegression"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {Bytes.empty, GRPC::Status.unimplemented("unary not implemented")}
  end

  def server_streaming?(method : String) : Bool
    true
  end

  def dispatch_server_stream(method : String, request_body : Bytes,
                             ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    12.times do |index|
      writer.send_raw(Bytes.new(256 * 1024, index.to_u8))
    end
    if method == "RaiseAfterData"
      raise GRPC::StatusError.new(GRPC::StatusCode::RESOURCE_EXHAUSTED, "stream exhausted")
    end
    GRPC::Status.ok
  end
end

describe "GRPC streaming regressions" do
  ["LargeMessages", "RaiseAfterData"].each do |method|
    it "delivers complete multi-frame messages for #{method}" do
      server = GRPC::Server.new
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.local_address.port
      listener.close
      server.handle StreamingRegressionService.new
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        ctx = GRPC::ClientContext.new(deadline: Time.utc + 10.seconds)
        stream = channel.open_server_stream("test.StreamingRegression", method, Bytes.empty, ctx)
        received = 0
        stream.each do |message|
          message.should eq(Bytes.new(256 * 1024, received.to_u8))
          received += 1
        end
        received.should eq(12)
        if method == "RaiseAfterData"
          stream.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
          stream.status.message.should eq("stream exhausted")
        else
          stream.status.ok?.should be_true
        end
      ensure
        channel.close
        server.stop
      end
    end
  end
end
