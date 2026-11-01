require "../spec_helper"
require "../support/fake_transports"

describe "transport factory integration" do
  it "uses custom client transport factory in Channel" do
    created = 0
    fake = FakeClientTransport.new

    factory = ->(_host : String, _port : Int32, _use_tls : Bool, _tls_ctx : OpenSSL::SSL::Context::Client?, _config : GRPC::EndpointConfig) {
      created += 1
      fake.as(GRPC::Transport::ClientTransport)
    }

    channel = GRPC::Channel.new("127.0.0.1:12345", transport_factory: factory)

    begin
      response = channel.unary_call("test.Echo", "Echo", Bytes[1, 2, 3])
      response.status.ok?.should be_true
      response.raw.should eq(Bytes[1, 2, 3])
      created.should eq(1)
      fake.unary_calls.should eq(1)
    ensure
      channel.close
    end
  end

  it "recreates the client transport after the previous one is closed" do
    created = [] of CyclingClientTransport
    factory = ->(_host : String, _port : Int32, _use_tls : Bool, _tls_ctx : OpenSSL::SSL::Context::Client?, _config : GRPC::EndpointConfig) {
      transport = CyclingClientTransport.new(created.size + 1)
      created << transport
      transport.as(GRPC::Transport::ClientTransport)
    }

    channel = GRPC::Channel.new("127.0.0.1:12345", transport_factory: factory)

    begin
      first_response = channel.unary_call("test.Echo", "Echo", Bytes.empty)
      first_response.raw.should eq(Bytes[1_u8])
      created.size.should eq(1)

      created.first.close

      second_response = channel.unary_call("test.Echo", "Echo", Bytes.empty)
      second_response.raw.should eq(Bytes[2_u8])
      created.size.should eq(2)
    ensure
      channel.close
    end
  end

  it "uses custom server transport factory in Server" do
    started = ::Channel(Nil).new(1)
    created = 0

    factory = ->(_io : IO, _services : Hash(String, GRPC::Service), _interceptors : Array(GRPC::ServerInterceptor), _peer : String, _tls_sock : OpenSSL::SSL::Socket::Server?) {
      created += 1
      FakeServerTransport.new(started).as(GRPC::Transport::ServerTransport)
    }

    port_server = TCPServer.new("127.0.0.1", 0)
    port = port_server.local_address.port
    port_server.close

    server = GRPC::Server.new(transport_factory: factory)
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      client = TCPSocket.new("127.0.0.1", port)
      client.close

      select
      when started.receive
      when timeout(1.second)
        fail "custom server transport factory was not used"
      end

      created.should eq(1)
    ensure
      server.stop
    end
  end

  it "closes active server transports on stop" do
    transport = BlockingServerTransport.new

    factory = ->(_io : IO, _services : Hash(String, GRPC::Service), _interceptors : Array(GRPC::ServerInterceptor), _peer : String, _tls_sock : OpenSSL::SSL::Socket::Server?) {
      transport.as(GRPC::Transport::ServerTransport)
    }

    port_server = TCPServer.new("127.0.0.1", 0)
    port = port_server.local_address.port
    port_server.close

    server = GRPC::Server.new(transport_factory: factory)
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      client = TCPSocket.new("127.0.0.1", port)
      client.close

      select
      when transport.started.receive
      when timeout(1.second)
        fail "server transport did not start"
      end

      server.stop

      select
      when transport.closed_signal.receive
      when timeout(1.second)
        fail "server stop did not close the active transport"
      end

      transport.closed?.should be_true
    ensure
      server.stop
    end
  end
end
