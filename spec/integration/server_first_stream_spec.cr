require "../spec_helper"
require "../support/integration_helpers"

private class ServerFirstService < GRPC::Service
  getter client_started = Channel(Nil).new(1)

  def service_full_name : String
    "test.ServerFirst"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {Bytes.empty, GRPC::Status.unimplemented}
  end

  def bidi_streaming?(method : String) : Bool
    method == "Bidi"
  end

  def client_streaming?(method : String) : Bool
    method == "Client"
  end

  def dispatch_bidi_stream(method : String, requests : GRPC::RawRequestStream,
                           ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    writer.send_raw(Bytes[42])
    requests.each { |request| writer.send_raw(request) }
    GRPC::Status.ok
  end

  def dispatch_client_stream(method : String, requests : GRPC::RawRequestStream,
                             ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    @client_started.send(nil)
    requests.each { |_| }
    {Bytes[7], GRPC::Status.ok}
  end
end

describe "server request streaming dispatch" do
  it "sends a bidi response before the client sends a message or closes" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle(ServerFirstService.new)
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    call = channel.open_bidi_stream_live("test.ServerFirst", "Bidi", GRPC::ClientContext.new(deadline: 3.seconds))
    replies = Channel(Bytes).new(2)
    done = Channel(Nil).new(1)
    spawn do
      call.each { |reply| replies.send(reply) }
      done.send(nil)
    end
    begin
      select
      when reply = replies.receive
        reply.should eq(Bytes[42])
      when timeout(1.second)
        fail "server did not send its first response"
      end
      call.send_raw(Bytes[7])
      call.close_send
      select
      when reply = replies.receive
        reply.should eq(Bytes[7])
      when timeout(1.second)
        fail "server did not echo the request"
      end
      select
      when done.receive
      when timeout(1.second)
        fail "server did not complete"
      end
      call.status.ok?.should be_true
    ensure
      call.cancel
      channel.close
      server.stop
    end
  end

  it "starts a client-streaming handler before the first message" do
    port = find_free_port
    service = ServerFirstService.new
    server = GRPC::Server.new
    server.handle(service)
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    call = channel.open_client_stream_live("test.ServerFirst", "Client", GRPC::ClientContext.new(deadline: 3.seconds))
    begin
      select
      when service.client_started.receive
      when timeout(1.second)
        fail "client-streaming handler did not start on HEADERS"
      end
      call.close_and_recv.should eq(Bytes[7])
      call.status.ok?.should be_true
    ensure
      call.cancel
      channel.close
      server.stop
    end
  end
end
