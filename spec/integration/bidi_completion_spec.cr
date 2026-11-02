require "../spec_helper"
require "../support/integration_helpers"

private class CompletingBidiService < GRPC::Service
  def initialize(@status : GRPC::Status)
  end

  def service_full_name : String
    "test.CompletingBidi"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {Bytes.empty, GRPC::Status.unimplemented}
  end

  def bidi_streaming?(method : String) : Bool
    method == "Finish"
  end

  def dispatch_bidi_stream(method : String, requests : GRPC::RawRequestStream,
                           ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    requests.each do |body|
      writer.send_raw(body)
      break
    end
    @status
  end
end

describe "GRPC bidirectional RPC completion" do
  [GRPC::Status.ok, GRPC::Status.unavailable("peer stopped")].each do |status|
    it "exposes #{status.code} before draining the final response and rejects further sends" do
      port = find_free_port
      server = GRPC::Server.new
      server.handle(CompletingBidiService.new(status))
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")
      begin
        call = channel.open_bidi_stream_live("test.CompletingBidi", "Finish")
        call.final_status.should be_nil
        call.send_raw(Bytes[42_u8])
        completed = Channel(GRPC::Status).new(1)
        spawn do
          loop do
            if final = call.final_status
              completed.send(final)
              break
            end
            Fiber.yield
          end
        end
        select
        when final = completed.receive
          final.should eq(status)
        when timeout(2.seconds)
          fail "RPC completion required consuming the response or closing the request side"
        end
        ex = expect_raises(GRPC::SendClosedError) { call.send_raw(Bytes[99_u8]) }
        ex.final_status.should eq(status)
        call.to_a.should eq([Bytes[42_u8]])
        call.status.should eq(status)
      ensure
        channel.close
        server.stop
      end
    end
  end
end
