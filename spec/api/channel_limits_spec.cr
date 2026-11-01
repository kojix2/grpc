require "../spec_helper"
require "../support/fake_transports"

describe GRPC::Channel do
  describe "concurrency limits" do
    it "enforces concurrency_limit for unary calls" do
      transport = BlockingUnaryTransport.new
      factory = ->(_host : String, _port : Int32, _use_tls : Bool, _tls_ctx : OpenSSL::SSL::Context::Client?, _config : GRPC::EndpointConfig) {
        transport.as(GRPC::Transport::ClientTransport)
      }
      config = GRPC::EndpointConfig.new(concurrency_limit: 1)
      channel = GRPC::Channel.new("127.0.0.1:12345", endpoint_config: config, transport_factory: factory)

      done1 = ::Channel(Nil).new(1)
      done2 = ::Channel(Nil).new(1)

      spawn do
        channel.unary_call("test.Echo", "Echo", Bytes[1])
        done1.send(nil)
      end

      select
      when transport.started.receive
      when timeout(1.second)
        fail "first unary call did not start"
      end

      spawn do
        channel.unary_call("test.Echo", "Echo", Bytes[2])
        done2.send(nil)
      end

      select
      when transport.started.receive
        fail "second unary call started before first finished"
      when timeout(120.milliseconds)
        # expected: second call is blocked by concurrency limit
      end

      transport.releases.send(nil)

      select
      when done1.receive
      when timeout(1.second)
        fail "first unary call did not complete"
      end

      select
      when transport.started.receive
      when timeout(1.second)
        fail "second unary call did not start after slot release"
      end

      transport.releases.send(nil)

      select
      when done2.receive
      when timeout(1.second)
        fail "second unary call did not complete"
      end

      channel.close
    end

    it "releases concurrency slot when server stream is cancelled" do
      transport = BlockingServerStreamTransport.new
      factory = ->(_host : String, _port : Int32, _use_tls : Bool, _tls_ctx : OpenSSL::SSL::Context::Client?, _config : GRPC::EndpointConfig) {
        transport.as(GRPC::Transport::ClientTransport)
      }
      config = GRPC::EndpointConfig.new(concurrency_limit: 1)
      channel = GRPC::Channel.new("127.0.0.1:12345", endpoint_config: config, transport_factory: factory)

      stream1 = channel.open_server_stream("test.Stream", "Watch", Bytes.empty)

      select
      when transport.started.receive
      when timeout(1.second)
        fail "first stream did not start"
      end

      stream2_ready = ::Channel(Nil).new(1)
      spawn do
        channel.open_server_stream("test.Stream", "Watch", Bytes.empty)
        stream2_ready.send(nil)
      end

      select
      when transport.started.receive
        fail "second stream started before first stream released its slot"
      when timeout(120.milliseconds)
        # expected: blocked by concurrency limit
      end

      stream1.cancel

      select
      when transport.started.receive
      when timeout(1.second)
        fail "second stream did not start after first stream cancellation"
      end

      select
      when stream2_ready.receive
      when timeout(1.second)
        fail "second stream call did not return"
      end

      channel.close
    end

    it "releases concurrency slots when a unary interceptor raises" do
      transport = BlockingUnaryTransport.new
      factory = ->(_host : String, _port : Int32, _use_tls : Bool, _tls_ctx : OpenSSL::SSL::Context::Client?, _config : GRPC::EndpointConfig) {
        transport.as(GRPC::Transport::ClientTransport)
      }
      channel = GRPC::Channel.new(
        "127.0.0.1:12345",
        interceptors: [FailingClientInterceptor.new] of GRPC::ClientInterceptor,
        endpoint_config: GRPC::EndpointConfig.new(concurrency_limit: 1),
        transport_factory: factory,
      )

      2.times do
        done = ::Channel(Nil).new(1)
        spawn do
          begin
            channel.unary_call("test.Echo", "Echo", Bytes[1])
            fail "expected interceptor to raise"
          rescue ex : GRPC::StatusError
            ex.code.should eq(GRPC::StatusCode::INTERNAL)
            done.send(nil)
          end
        end

        select
        when done.receive
        when timeout(1.second)
          fail "interceptor-raised unary call leaked its concurrency slot"
        end
      end

      select
      when transport.started.receive
        fail "failing interceptor should prevent the transport from being called"
      when timeout(120.milliseconds)
        # expected: interceptor failed before transport invocation
      end

      channel.close
    end
  end

  describe "rate limits" do
    it "enforces rate_limit between request starts" do
      transport = TimestampUnaryTransport.new
      factory = ->(_host : String, _port : Int32, _use_tls : Bool, _tls_ctx : OpenSSL::SSL::Context::Client?, _config : GRPC::EndpointConfig) {
        transport.as(GRPC::Transport::ClientTransport)
      }
      config = GRPC::EndpointConfig.new(
        rate_limit: GRPC::RateLimitConfig.new(1_u64, 100.milliseconds)
      )
      channel = GRPC::Channel.new("127.0.0.1:12345", endpoint_config: config, transport_factory: factory)

      channel.unary_call("test.Echo", "Echo", Bytes[1])
      channel.unary_call("test.Echo", "Echo", Bytes[2])

      transport.starts.size.should eq(2)
      delta = transport.starts[1] - transport.starts[0]
      delta.should be >= 90.milliseconds

      channel.close
    end
  end
end
