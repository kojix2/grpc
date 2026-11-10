require "../spec_helper"
require "../support/integration_helpers"

private class TcpKeepaliveProbe < GRPC::Transport::Http2ClientConnection
  def keepalive_idle : Int32?
    socket = @socket.as(TCPSocket)
    if socket.responds_to?(:tcp_keepalive_idle)
      socket.tcp_keepalive_idle.to_i32
    end
  end
end

describe "GRPC connect timeout" do
  it "fails quickly when endpoint is unreachable and connect_timeout is set" do
    config = GRPC::EndpointConfig.new(connect_timeout: 100.milliseconds)
    channel = GRPC::Channel.new("10.255.255.1:6553", endpoint_config: config)

    begin
      started = Time.instant
      raised = false
      begin
        channel.unary_call("test.Echo", "Echo", Bytes.empty)
      rescue
        raised = true
      end

      raised.should be_true
      elapsed = Time.instant - started
      elapsed.should be < 2.seconds
    ensure
      channel.close
    end
  end
end

describe "GRPC keepalive settings" do
  it "applies the TCP idle interval where the platform exposes it" do
    listener = TCPServer.new("127.0.0.1", 0)
    accepted = Channel(TCPSocket).new(1)
    spawn { accepted.send(listener.accept) }
    config = GRPC::EndpointConfig.new(tcp_keepalive: 10.seconds)
    connection = TcpKeepaliveProbe.new("127.0.0.1", listener.local_address.port, endpoint_config: config)
    peer = accepted.receive
    begin
      if idle = connection.keepalive_idle
        idle.should eq(10)
      end
    ensure
      peer.close
      listener.close
      connection.close
    end
  end

  it "can perform unary RPC with keepalive options enabled" do
    port = find_free_port
    server = start_test_server(port)
    config = GRPC::EndpointConfig.new(
      tcp_keepalive: 2.seconds,
      keepalive: GRPC::KeepaliveParams.new(interval: 2.seconds, timeout: 1.second)
    )
    channel = GRPC::Channel.new("127.0.0.1:#{port}", endpoint_config: config)

    begin
      response = channel.unary_call("test.Echo", "Echo", TestProto.encode_string("ka"))
      response.status.ok?.should be_true
      TestProto.decode_string(response.raw).should eq("echo:ka")
    ensure
      channel.close
      server.stop
    end
  end
end
