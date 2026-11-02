require "../support/protocol_peer"

describe "GRPC HTTP/2 client lifecycle" do
  {false, true}.each do |expired|
    {false, true}.each do |streaming|
      it "maps peer CANCEL with expired=#{expired}, streaming=#{streaming} before the timer runs" do
        with_protocol_peer("controlled_reset") do |connection, peer|
          result = Channel(GRPC::Status).new(1)
          metadata = GRPC::Metadata.new({"grpc-timeout" => "30S"})
          spawn do
            if streaming
              call = connection.open_bidi_stream_live("test.Service", "Bidi", metadata)
              call.to_a.should be_empty
              result.send(call.status)
            else
              result.send(connection.unary_call("test.Service", "Unary", Bytes.empty, metadata).status)
            end
          end
          wait_for_protocol_state { peer.requests == 1 }
          connection.expire_recorded_deadlines if expired
          peer.reset_accepted_call
          select
          when status = result.receive
            status.code.should eq(expired ? GRPC::StatusCode::DEADLINE_EXCEEDED : GRPC::StatusCode::CANCELLED)
          when timeout(2.seconds)
            fail "peer reset did not finish the RPC"
          end
          wait_for_protocol_state { connection.pending_count == 0 }
        end
      end
    end
  end

  it "releases early-completed bidi requests before opening another call at stream limit one" do
    with_protocol_peer("early") do |connection, peer|
      2.times do
        call = connection.open_bidi_stream_live("test.Service", "Bidi")
        call.send_raw(Bytes[1])
        wait_for_protocol_state { !call.final_status.nil? && connection.pending_count == 0 }
        call.final_status.should eq(GRPC::Status.ok)
        call.to_a.should be_empty
      end
      peer.requests.should eq(2)
    end
  end

  it "maps a real HTTP 503 response without grpc-status to UNAVAILABLE" do
    with_protocol_peer("http503") do |connection, _peer|
      connection.unary_call("test.Service", "Unary", Bytes.empty).status.code.should eq(GRPC::StatusCode::UNAVAILABLE)
    end
  end

  { 0_u32 => GRPC::StatusCode::INTERNAL,
    7_u32 => GRPC::StatusCode::UNAVAILABLE,
    8_u32 => GRPC::StatusCode::CANCELLED,
   11_u32 => GRPC::StatusCode::RESOURCE_EXHAUSTED,
   12_u32 => GRPC::StatusCode::PERMISSION_DENIED,
    1_u32 => GRPC::StatusCode::INTERNAL}.each do |reset, code|
    it "maps RST_STREAM #{reset} to #{code}" do
      with_protocol_peer("reset", reset) do |connection, _peer|
        connection.unary_call("test.Service", "Unary", Bytes.empty).status.code.should eq(code)
      end
    end
  end

  {"empty" => GRPC::StatusCode::INTERNAL, "single" => GRPC::StatusCode::OK, "double" => GRPC::StatusCode::INTERNAL}.each do |mode, code|
    it "validates a #{mode} client-streaming response including a valid zero-length message" do
      with_protocol_peer(mode) do |connection, _peer|
        call = connection.open_client_stream_live("test.Service", "Upload")
        call.send_raw(Bytes[1])
        call.close_and_recv
        call.status.code.should eq(code)
      end
    end
  end

  it "replaces a GOAWAY connection while preserving the accepted RPC and closes it when drained" do
    listener = TCPServer.new("127.0.0.1", 0)
    accepted = Channel(ProtocolPeer).new(2)
    peers = [] of ProtocolPeer
    spawn do
      2.times do |index|
        peer = ProtocolPeer.new(listener.accept, index == 0 ? "goaway" : "early")
        peers << peer
        accepted.send(peer)
        spawn { peer.run_recv_loop }
      end
    rescue IO::Error
    end
    connections = [] of InspectableClientConnection
    factory = ->(host : String, port : Int32, tls : Bool, ctx : OpenSSL::SSL::Context::Client?, config : GRPC::EndpointConfig) {
      connection = InspectableClientConnection.new(host, port, tls, ctx, config)
      connections << connection
      connection.as(GRPC::Transport::ClientTransport)
    }
    channel = GRPC::Channel.new("127.0.0.1:#{listener.local_address.port}", transport_factory: factory)
    begin
      first = channel.open_bidi_stream_live("test.Service", "Bidi")
      original = accepted.receive
      wait_for_protocol_state { !connections.first.accepting_new_calls? }
      connections.first.closed?.should be_false
      first.final_status.should be_nil
      second = channel.open_bidi_stream_live("test.Service", "Bidi")
      second.send_raw(Bytes[2])
      wait_for_protocol_state { !second.final_status.nil? }
      second.final_status.should eq(GRPC::Status.ok)
      connections.size.should eq(2)
      first.final_status.should be_nil
      original.finish_accepted_call
      wait_for_protocol_state { !first.final_status.nil? && connections.first.closed? }
      first.final_status.should eq(GRPC::Status.ok)
    ensure
      channel.close
      peers.each(&.close)
      listener.close
    end
  end
end
