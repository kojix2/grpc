require "../spec_helper"
require "../support/integration_helpers"

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
