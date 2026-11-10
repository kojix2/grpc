# Explicit suite: requires the updated proto.cr runtime and generated fixture.
require "./spec_helper"
require "./support/integration_helpers"
require "./protobuf_options/large.pb"
require "./protobuf_options/large.grpc"

private class LargeOptionsService < OptionsTest::Large::Service
  def echo(request : OptionsTest::Blob, ctx : GRPC::ServerContext) : OptionsTest::Blob
    if request.value == Bytes[7]
      response = OptionsTest::Blob.new
      response.value = Bytes.new(9 * 1024 * 1024, 42_u8)
      return response
    end
    request
  end
end

describe "generated gRPC protobuf limits" do
  it "round-trips a field above 8 MiB with explicit client and server options" do
    port = find_free_port
    options = GRPC::ProtobufOptions.new(max_field_length: 10 * 1024 * 1024)
    server = GRPC::Server.new(protobuf_options: options)
    server.handle(LargeOptionsService.new)
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    begin
      client = OptionsTest::Large::Client.new(channel)
      message = OptionsTest::Blob.new
      message.value = Bytes.new(9 * 1024 * 1024, 42_u8)
      error = expect_raises(GRPC::StatusError) { client.echo(message) }
      error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      ctx = GRPC::ClientContext.new(deadline: 10.seconds, protobuf_options: options)
      client.echo(message, ctx).value.should eq(message.value)
    ensure
      channel.close
      server.stop
    end
  end
  it "reports the server's protobuf decode budget independently of the client limit" do
    port = find_free_port
    server = GRPC::Server.new(protobuf_options: GRPC::ProtobufOptions.new)
    server.handle(LargeOptionsService.new)
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    begin
      message = OptionsTest::Blob.new
      message.value = Bytes.new(9 * 1024 * 1024, 42_u8)
      options = GRPC::ProtobufOptions.new(max_field_length: 10 * 1024 * 1024)
      error = expect_raises(GRPC::StatusError) do
        OptionsTest::Large::Client.new(channel).echo(message, GRPC::ClientContext.new(deadline: 10.seconds, protobuf_options: options))
      end
      error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      error.message.should contain("protobuf decode")
    ensure
      channel.close
      server.stop
    end
  end

  it "reports the client's protobuf decode budget on a large server response" do
    port = find_free_port
    options = GRPC::ProtobufOptions.new(max_field_length: 10 * 1024 * 1024)
    server = GRPC::Server.new(protobuf_options: options)
    server.handle(LargeOptionsService.new)
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    begin
      message = OptionsTest::Blob.new
      message.value = Bytes[7]
      error = expect_raises(GRPC::StatusError) do
        OptionsTest::Large::Client.new(channel).echo(message, GRPC::ClientContext.new(deadline: 10.seconds))
      end
      error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      error.message.should contain("protobuf decode")
    ensure
      channel.close
      server.stop
    end
  end
end
