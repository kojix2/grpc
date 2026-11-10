require "../spec_helper"

describe "HTTP/2 socket write backpressure" do
  it "lets a deadline finish while the peer stops reading outbound data" do
    listener = TCPServer.new("127.0.0.1", 0)
    peer_ready = Channel(TCPSocket).new(1)
    spawn do
      peer = listener.accept
      # Allow a large HTTP/2 send window, then stop reading. This fills the
      # socket buffer instead of merely exhausting HTTP/2 stream credit.
      peer.write(Bytes[0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 4, 127, 255, 255, 255])
      peer.write(Bytes[0, 0, 4, 8, 0, 0, 0, 0, 0, 127, 255, 0, 0])
      peer.flush
      peer_ready.send(peer)
    end
    channel = GRPC::Channel.new("127.0.0.1:#{listener.local_address.port}")
    result = Channel(GRPC::StatusCode).new(1)
    spawn do
      response = channel.unary_call("test.Service", "Echo", Bytes.new(8 * 1024 * 1024),
        GRPC::ClientContext.new(deadline: 200.milliseconds))
      result.send(response.status.code)
    rescue ex : GRPC::StatusError
      result.send(ex.code)
    end
    peer = peer_ready.receive
    begin
      select
      when status = result.receive
        status.should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
      when timeout(1.second)
        fail "socket write prevented the RPC deadline from completing"
      end
    ensure
      peer.close
      listener.close
      channel.close
    end
  end

  it "closes the channel and wakes an RPC while a peer does not read" do
    listener = TCPServer.new("127.0.0.1", 0)
    peer_ready = Channel(TCPSocket).new(1)
    spawn do
      peer = listener.accept
      peer.write(Bytes[0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 4, 127, 255, 255, 255])
      peer.write(Bytes[0, 0, 4, 8, 0, 0, 0, 0, 0, 127, 255, 0, 0])
      peer.flush
      peer_ready.send(peer)
    end
    channel = GRPC::Channel.new("127.0.0.1:#{listener.local_address.port}")
    result = Channel(GRPC::StatusCode).new(1)
    spawn do
      response = channel.unary_call("test.Service", "Echo", Bytes.new(8 * 1024 * 1024))
      result.send(response.status.code)
    rescue ex : GRPC::StatusError
      result.send(ex.code)
    end
    peer = peer_ready.receive
    begin
      sleep 50.milliseconds
      closed = Channel(Nil).new(1)
      spawn { channel.close; closed.send(nil) }
      select
      when closed.receive
      when timeout(1.second)
        fail "channel close waited indefinitely for the socket writer"
      end
      select
      when status = result.receive
        status.should eq(GRPC::StatusCode::UNAVAILABLE)
      when timeout(1.second)
        fail "channel close did not wake the pending RPC"
      end
    ensure
      peer.close
      listener.close
      channel.close
    end
  end
end
