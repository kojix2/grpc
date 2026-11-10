require "../spec_helper"
require "../support/integration_helpers"

describe "TLS handshake deadlines" do
  it "lets an RPC deadline expire while the peer stalls during the handshake" do
    listener = TCPServer.new("127.0.0.1", 0)
    accepted = Channel(TCPSocket).new(1)
    spawn { accepted.send(listener.accept) }
    context = OpenSSL::SSL::Context::Client.new
    context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    channel = GRPC::Channel.new("https://127.0.0.1:#{listener.local_address.port}", tls_context: context,
      endpoint_config: GRPC::EndpointConfig.new(connect_timeout: 2.seconds))
    result = Channel(GRPC::StatusCode).new(1)
    spawn do
      channel.unary_call("test.Service", "Echo", Bytes.empty, GRPC::ClientContext.new(deadline: 50.milliseconds))
    rescue ex : GRPC::StatusError
      result.send(ex.code)
    end
    peer = accepted.receive
    begin
      select
      when code = result.receive
        code.should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
      when timeout(1.second)
        fail "RPC waited for the stalled TLS handshake"
      end
    ensure
      peer.close
      listener.close
      channel.close
    end
  end

  it "bounds a stalled TLS handshake with the connection timeout" do
    listener = TCPServer.new("127.0.0.1", 0)
    accepted = Channel(TCPSocket).new(1)
    spawn { accepted.send(listener.accept) }
    context = OpenSSL::SSL::Context::Client.new
    context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    channel = GRPC::Channel.new("https://127.0.0.1:#{listener.local_address.port}", tls_context: context,
      endpoint_config: GRPC::EndpointConfig.new(connect_timeout: 100.milliseconds))
    result = Channel(Exception).new(1)
    spawn do
      channel.unary_call("test.Service", "Echo", Bytes.empty)
    rescue ex
      result.send(ex)
    end
    peer = accepted.receive
    begin
      select
      when result.receive
      when timeout(2.seconds)
        fail "TLS handshake exceeded the connection timeout"
      end
    ensure
      peer.close
      listener.close
      channel.close
    end
  end
end

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

describe "GRPC TLS ALPN" do
  it "negotiates h2 with custom contexts on both sides" do
    negotiated = Channel(String?).new(1)
    factory = ->(io : IO, services : Hash(String, GRPC::Service), interceptors : Array(GRPC::ServerInterceptor), peer : String, tls : OpenSSL::SSL::Socket::Server?) {
      negotiated.send(tls.try &.alpn_protocol)
      GRPC::Transport::Http2ServerConnection.new(io, services, interceptors, peer, tls).as(GRPC::Transport::ServerTransport)
    }
    server = GRPC::Server.new(transport_factory: factory)
    context = OpenSSL::SSL::Context::Server.new
    context.certificate_chain = TLS_CERT
    context.private_key = TLS_KEY
    server.use_tls(context)
    server.handle(EchoService.new)
    port = find_free_port
    server.bind("127.0.0.1:#{port}")
    server.start
    client_context = OpenSSL::SSL::Context::Client.new
    client_context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    channel = GRPC::Channel.new("https://127.0.0.1:#{port}", tls_context: client_context)
    channel.unary_call("test.Echo", "Echo", Bytes.empty).status.ok?.should be_true
    negotiated.receive.should eq("h2")
  ensure
    channel.try &.close
    server.try &.stop
  end

  it "rejects a TLS peer that does not negotiate h2" do
    listener = TCPServer.new("127.0.0.1", 0)
    context = OpenSSL::SSL::Context::Server.new
    context.certificate_chain = TLS_CERT
    context.private_key = TLS_KEY
    done = Channel(Exception?).new(1)
    spawn do
      tcp = nil.as(TCPSocket?)
      socket = nil.as(OpenSSL::SSL::Socket::Server?)
      error = nil.as(Exception?)
      begin
        tcp = listener.accept
        tcp.read_timeout = 2.seconds
        tcp.write_timeout = 2.seconds
        socket = OpenSSL::SSL::Socket::Server.new(tcp, context, sync_close: true)
      rescue IO::Error
        # The client rejects ALPN and can disconnect while this peer is still
        # finishing its TLS handshake (Broken pipe on Linux/OpenSSL).
      rescue ex
        error = ex
      ensure
        socket.try(&.close) rescue nil
        tcp.try(&.close) rescue nil
        done.send(error)
      end
    end
    client_context = OpenSSL::SSL::Context::Client.new
    client_context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    expect_raises(GRPC::ConnectionError, "TLS peer did not negotiate h2 ALPN") do
      GRPC::Transport::Http2ClientConnection.new("127.0.0.1", listener.local_address.port, true, client_context)
    end
    select
    when error = done.receive
      raise error if error
    when timeout(3.seconds)
      fail "TLS peer did not finish after the client rejected missing h2 ALPN"
    end
  ensure
    listener.try &.close
  end
end
