require "../spec_helper"

private class KeepalivePeer < GRPC::Transport::Http2Connection
  getter pings = Channel(Nil).new(8)

  def initialize(socket : IO, @acknowledge : Bool, @goaway : Bool = false)
    super(socket)
    setup_session(server_side: true)
  end

  protected def configure_session_options(options : LibNghttp2::Option*) : Nil
    LibNghttp2.option_set_no_auto_ping_ack(options, 1)
  end

  def on_frame_recv_cb(frame : Void*) : Nil
    return unless frame_type(frame) == LibNghttp2::FRAME_PING
    return unless (frame_flags(frame) & LibNghttp2::FLAG_ACK) == 0
    select
    when @pings.send(nil)
    else
    end
    if @goaway
      reason = "too_many_pings".to_slice
      check LibNghttp2.submit_goaway(@session, LibNghttp2::FLAG_NONE, 0x7fffffff, 11_u32, reason.to_unsafe, reason.size)
    elsif @acknowledge
      ping = frame.as(LibNghttp2::Ping*).value
      check LibNghttp2.submit_ping(@session, LibNghttp2::FLAG_ACK, ping.opaque_data.to_unsafe)
    end
  end
end

private def with_keepalive_peer(acknowledge : Bool, permit_without_calls : Bool, goaway : Bool = false, &)
  listener = TCPServer.new("127.0.0.1", 0)
  peer_ready = Channel(KeepalivePeer).new(1)
  spawn do
    peer = KeepalivePeer.new(listener.accept, acknowledge, goaway)
    peer_ready.send(peer)
    peer.run_recv_loop
  rescue IO::Error
  end
  config = GRPC::EndpointConfig.new(keepalive: GRPC::KeepaliveParams.new(
    interval: 25.milliseconds, timeout: 100.milliseconds, permit_without_calls: permit_without_calls))
  connection = GRPC::Transport::Http2ClientConnection.new("127.0.0.1", listener.local_address.port, endpoint_config: config)
  peer = peer_ready.receive
  yield connection, peer
ensure
  connection.try &.close
  peer.try &.close
  listener.try &.close
end

describe "HTTP/2 keepalive" do
  it "accepts matching PING acknowledgments and stays connected" do
    with_keepalive_peer(true, true) do |connection, peer|
      2.times do
        select
        when peer.pings.receive
        when timeout(1.second)
          fail "keepalive PING was not sent"
        end
      end
      connection.closed?.should be_false
    end
  end

  it "does not send idle PINGs when permit_without_calls is false" do
    with_keepalive_peer(true, false) do |connection, peer|
      select
      when peer.pings.receive
        fail "idle connection sent a PING"
      when timeout(100.milliseconds)
      end
      connection.closed?.should be_false
    end
  end

  it "fails an active stream when the peer does not acknowledge a PING" do
    with_keepalive_peer(false, false) do |connection, peer|
      call = connection.open_bidi_stream_live("test.Service", "Wait")
      completed = Channel(Nil).new(1)
      spawn do
        call.each { |_| }
        completed.send(nil)
      end
      select
      when peer.pings.receive
      when timeout(1.second)
        fail "active stream did not trigger a PING"
      end
      select
      when completed.receive
        call.status.code.should eq(GRPC::StatusCode::UNAVAILABLE)
      when timeout(1.second)
        fail "missing PING acknowledgment did not close the stream"
      end
    end
  end

  it "stops accepting new calls after a too_many_pings GOAWAY" do
    with_keepalive_peer(false, true, goaway: true) do |connection, peer|
      select
      when peer.pings.receive
      when timeout(1.second)
        fail "keepalive PING was not sent"
      end
      deadline = Time.instant + 1.second
      while connection.accepting_new_calls?
        fail "GOAWAY did not drain the connection" if Time.instant >= deadline
        sleep 1.millisecond
      end
    end
  end
end
