require "../spec_helper"
require "../support/integration_helpers"

private class ContextCancellationService < GRPC::Service
  getter started = Channel(Nil).new(1)

  def service_full_name : String
    "test.ContextCancellation"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    @started.send(nil)
    until ctx.cancelled?
      sleep 1.millisecond
    end
    {Bytes.empty, GRPC::Status.cancelled}
  end

  def bidi_streaming?(method : String) : Bool
    method == "Bidi"
  end

  def dispatch_bidi_stream(method : String, requests : GRPC::RawRequestStream,
                           ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    @started.send(nil)
    requests.each { |_| }
    GRPC::Status.ok
  end
end

describe "client context cancellation" do
  it "cancels an already submitted unary RPC" do
    port = find_free_port
    service = ContextCancellationService.new
    server = GRPC::Server.new
    server.handle(service)
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    ctx = GRPC::ClientContext.new(deadline: 3.seconds)
    result = Channel(GRPC::ResponseEnvelope).new(1)
    spawn { result.send(channel.unary_call("test.ContextCancellation", "Wait", Bytes.empty, ctx)) }
    begin
      service.started.receive
      ctx.cancel
      select
      when response = result.receive
        response.status.code.should eq(GRPC::StatusCode::CANCELLED)
      when timeout(1.second)
        fail "unary RPC did not finish after context cancellation"
      end
    ensure
      ctx.cancel
      channel.close
      server.stop
    end
  end

  it "cancels an open bidirectional RPC and wakes its reader" do
    port = find_free_port
    service = ContextCancellationService.new
    server = GRPC::Server.new
    server.handle(service)
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    ctx = GRPC::ClientContext.new(deadline: 3.seconds)
    call = channel.open_bidi_stream_live("test.ContextCancellation", "Bidi", ctx)
    done = Channel(Nil).new(1)
    spawn do
      call.each { |_| }
      done.send(nil)
    end
    begin
      service.started.receive
      ctx.cancel
      select
      when done.receive
        call.status.code.should eq(GRPC::StatusCode::CANCELLED)
      when timeout(1.second)
        fail "bidi reader did not finish after context cancellation"
      end
    ensure
      call.cancel
      channel.close
      server.stop
    end
  end
end
