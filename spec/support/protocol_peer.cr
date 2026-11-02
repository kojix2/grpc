require "../spec_helper"

# A small HTTP/2 peer for protocol and lifecycle cases the normal server avoids.
class ProtocolPeer < GRPC::Transport::Http2Connection
  getter requests = 0
  getter settings_ack = Channel(Nil).new(1)
  @responded = Set(Int32).new
  @response_contexts = [] of GRPC::Transport::ResponseContext
  @response_boxes = [] of Void*

  def initialize(socket : IO, @mode : String, @reset_code : UInt32 = 7_u32)
    super(socket)
    setup_session(server_side: true)
    settings = StaticArray[LibNghttp2::SettingsEntry.new(settings_id: LibNghttp2::SETTINGS_MAX_CONCURRENT_STREAMS, value: 1_u32)]
    check LibNghttp2.submit_settings(@session, LibNghttp2::FLAG_NONE, settings.to_unsafe, settings.size)
    flush_send
  end

  def on_frame_recv_cb(frame : Void*) : Nil
    if frame_type(frame) == LibNghttp2::FRAME_SETTINGS && (frame_flags(frame) & LibNghttp2::FLAG_ACK) != 0
      select
      when @settings_ack.send(nil)
      else
      end
    end
    stream = frame_stream_id(frame)
    return if stream <= 0
    if frame_type(frame) == LibNghttp2::FRAME_HEADERS
      @requests += 1
      if @mode == "goaway"
        check LibNghttp2.submit_goaway(@session, LibNghttp2::FLAG_NONE, 0x7fffffff, LibNghttp2::NO_ERROR, nil, 0)
        return
      end
    end
    return if @mode.in?("goaway", "controlled_reset")
    return unless frame_type(frame) == LibNghttp2::FRAME_DATA
    return unless @responded.add?(stream)
    respond_to_request(stream)
  end

  private def respond_to_request(stream : Int32) : Nil
    case @mode
    when "reset"
      check LibNghttp2.submit_rst_stream(@session, LibNghttp2::FLAG_NONE, stream, @reset_code)
    when "http503"
      headers = [make_nv(":status", "503"), make_nv("content-type", "text/plain")]
      check LibNghttp2.submit_headers(@session, LibNghttp2::FLAG_END_STREAM, stream, nil, headers.to_unsafe, headers.size, nil)
    when "empty", "early"
      respond(stream)
    else
      headers = [make_nv(":status", "200"), make_nv("content-type", "application/grpc")]
      body = GRPC::Codec.encode(Bytes.empty)
      body += GRPC::Codec.encode(Bytes[2]) if @mode == "double"
      ctx = GRPC::Transport::ResponseContext.new(body, stream, [{"grpc-status", "0"}])
      @response_contexts << ctx
      box = Box.box(ctx)
      @response_boxes << box
      src = LibNghttp2::DataSource.new(ptr: box)
      dp = LibNghttp2::DataProvider.new(source: src, read_callback: GRPC::Transport::Http2ServerConnection::DATA_READ_CB)
      check LibNghttp2.submit_response(@session, stream, headers.to_unsafe, headers.size, pointerof(dp))
    end
  end

  def finish_accepted_call : Nil
    @mutex.synchronize do
      respond(1)
      flush_send
    end
  end

  def reset_accepted_call : Nil
    @mutex.synchronize do
      check LibNghttp2.submit_rst_stream(@session, LibNghttp2::FLAG_NONE, 1, LibNghttp2::NGHTTP2_CANCEL)
      flush_send
    end
  end

  private def respond(stream : Int32) : Nil
    headers = [make_nv(":status", "200"), make_nv("content-type", "application/grpc"), make_nv("grpc-status", "0")]
    check LibNghttp2.submit_headers(@session, LibNghttp2::FLAG_END_STREAM, stream, nil, headers.to_unsafe, headers.size, nil)
  end
end

class InspectableClientConnection < GRPC::Transport::Http2ClientConnection
  def pending_count : Int32
    @mutex.synchronize { @pending.size + @pending_streams.size + @stream_boxes.size + @data_source_boxes.size }
  end

  # Force only the recorded deadline into the past. The real timer remains far
  # in the future, so the peer reset deterministically wins the callback race.
  def expire_recorded_deadlines : Nil
    @mutex.synchronize do
      @pending.each_value(&.deadline=(Time.instant - 1.second))
      @pending_streams.each_value(&.deadline=(Time.instant - 1.second))
    end
  end
end

def with_protocol_peer(mode : String, reset_code : UInt32 = 7_u32, &)
  listener = TCPServer.new("127.0.0.1", 0)
  accepted = Channel(ProtocolPeer).new(1)
  spawn do
    peer = ProtocolPeer.new(listener.accept, mode, reset_code)
    accepted.send(peer)
    peer.run_recv_loop
  rescue IO::Error
  end
  connection = InspectableClientConnection.new("127.0.0.1", listener.local_address.port)
  remote = accepted.receive
  remote.settings_ack.receive
  begin
    yield connection, remote
  ensure
    connection.close
    remote.close
    listener.close
  end
end

def wait_for_protocol_state(&condition : -> Bool) : Nil
  deadline = Time.instant + 2.seconds
  until condition.call
    raise "protocol state did not converge" if Time.instant >= deadline
    sleep 1.millisecond
  end
end
