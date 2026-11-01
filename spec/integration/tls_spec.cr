require "../spec_helper"
require "../support/integration_helpers"

describe "GRPC TLS integration" do
  it "performs a unary RPC round-trip over TLS" do
    port = find_free_port
    server = GRPC::Server.new
    server.use_tls(cert: TLS_CERT, key: TLS_KEY)
    server.handle EchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    ctx = OpenSSL::SSL::Context::Client.new
    ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    channel = GRPC::Channel.new("https://127.0.0.1:#{port}", tls_context: ctx)

    begin
      response = channel.unary_call("test.Echo", "Echo", TestProto.encode_string("tls"))
      response.status.ok?.should be_true
      TestProto.decode_string(response.raw).should eq("echo:tls")
    ensure
      channel.close
      server.stop
    end
  end

  it "performs a server-streaming RPC over TLS" do
    port = find_free_port
    server = GRPC::Server.new
    server.use_tls(cert: TLS_CERT, key: TLS_KEY)
    server.handle StreamingEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    ctx = OpenSSL::SSL::Context::Client.new
    ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    channel = GRPC::Channel.new("https://127.0.0.1:#{port}", tls_context: ctx)

    begin
      stream = channel.open_server_stream("test.StreamingEcho", "ServerStream",
        TestProto.encode_string("world"))
      messages = [] of String
      stream.each { |bytes| messages << TestProto.decode_string(bytes) }
      stream.status.ok?.should be_true
      messages.should eq(["0:world", "1:world", "2:world"])
    ensure
      channel.close
      server.stop
    end
  end
end
