require "../spec_helper"
require "../support/integration_helpers"

describe "GRPC compression integration" do
  it "handles a gzip-compressed request body" do
    port = find_free_port
    server = start_test_server(port)
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      raw = TestProto.encode_string("compressed")
      metadata = GRPC::Metadata.new
      metadata.add("grpc-encoding", "gzip")
      response = channel.unary_call("test.Echo", "Echo", raw, metadata)
      response.status.ok?.should be_true
      TestProto.decode_string(response.raw).should eq("echo:compressed")
      response.initial_metadata.get("grpc-accept-encoding").should eq("gzip")
    ensure
      channel.close
      server.stop
    end
  end
end
