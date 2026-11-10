require "../spec_helper"
require "../support/fake_transports"

private class ClosedSignalTransport < FakeClientTransport
  getter closed_signal = Channel(Nil).new(1)

  def close : Nil
    super
    @closed_signal.send(nil)
  end
end

describe "channel connection waiting" do
  it "lets a short deadline expire while another call shares the pending connection" do
    gate = Channel(Nil).new(1)
    started = Channel(Nil).new(1)
    created = 0
    transport = FakeClientTransport.new
    factory = ->(_host : String, _port : Int32, _tls : Bool, _tls_ctx : OpenSSL::SSL::Context::Client?, _config : GRPC::EndpointConfig) {
      created += 1
      started.send(nil)
      gate.receive
      transport.as(GRPC::Transport::ClientTransport)
    }
    channel = GRPC::Channel.new("localhost:12345", transport_factory: factory)
    short = Channel(GRPC::StatusCode).new(1)
    long = Channel(GRPC::ResponseEnvelope).new(1)
    spawn do
      channel.unary_call("test.Service", "Echo", Bytes.empty, GRPC::ClientContext.new(deadline: 50.milliseconds))
    rescue ex : GRPC::StatusError
      short.send(ex.code)
    end
    started.receive
    spawn { long.send(channel.unary_call("test.Service", "Echo", Bytes[42], GRPC::ClientContext.new(deadline: 2.seconds))) }
    begin
      select
      when code = short.receive
        code.should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
      when timeout(1.second)
        fail "deadline waited for the connection factory"
      end
      created.should eq(1)
      gate.send(nil)
      select
      when response = long.receive
        response.raw.should eq(Bytes[42])
      when timeout(1.second)
        fail "the remaining call did not use the shared connection"
      end
      created.should eq(1)
    ensure
      channel.close
    end
  end

  it "unblocks a cancelled connection waiter without cancelling the shared attempt" do
    gate = Channel(Nil).new(1)
    started = Channel(Nil).new(1)
    transport = FakeClientTransport.new
    factory = ->(_host : String, _port : Int32, _tls : Bool, _tls_ctx : OpenSSL::SSL::Context::Client?, _config : GRPC::EndpointConfig) {
      started.send(nil)
      gate.receive
      transport.as(GRPC::Transport::ClientTransport)
    }
    channel = GRPC::Channel.new("localhost:12345", transport_factory: factory)
    ctx = GRPC::ClientContext.new
    done = Channel(GRPC::StatusCode).new(1)
    spawn do
      channel.unary_call("test.Service", "Echo", Bytes.empty, ctx)
    rescue ex : GRPC::StatusError
      done.send(ex.code)
    end
    started.receive
    ctx.cancel
    begin
      select
      when code = done.receive
        code.should eq(GRPC::StatusCode::CANCELLED)
      when timeout(1.second)
        fail "cancellation waited for the connection factory"
      end
      gate.send(nil)
      channel.unary_call("test.Service", "Echo", Bytes[9]).raw.should eq(Bytes[9])
    ensure
      channel.close
    end
  end

  it "wakes waiters on close and disposes a connection that arrives afterward" do
    gate = Channel(Nil).new(1)
    started = Channel(Nil).new(1)
    transport = ClosedSignalTransport.new
    factory = ->(_host : String, _port : Int32, _tls : Bool, _tls_ctx : OpenSSL::SSL::Context::Client?, _config : GRPC::EndpointConfig) {
      started.send(nil)
      gate.receive
      transport.as(GRPC::Transport::ClientTransport)
    }
    channel = GRPC::Channel.new("localhost:12345", transport_factory: factory)
    done = Channel(Exception).new(1)
    spawn do
      channel.unary_call("test.Service", "Echo", Bytes.empty)
    rescue ex
      done.send(ex)
    end
    started.receive
    channel.close
    select
    when error = done.receive
      error.should be_a(GRPC::ConnectionError)
    when timeout(1.second)
      fail "channel close did not wake the connection waiter"
    end
    gate.send(nil)
    select
    when transport.closed_signal.receive
    when timeout(1.second)
      fail "late connection was not closed"
    end
  end
end
