require "../spec_helper"

class FakeClientTransport
  include GRPC::Transport::ClientTransport

  getter unary_calls = 0

  def initialize(@closed = false)
  end

  def unary_call(service : String, method : String,
                 request_body : Bytes, metadata : GRPC::Metadata) : GRPC::ResponseEnvelope
    @unary_calls += 1
    GRPC::ResponseEnvelope.new(
      GRPC::CallInfo.new("/#{service}/#{method}", GRPC::RPCKind::Unary),
      request_body,
      GRPC::Status.ok
    )
  end

  def open_server_stream(service : String, method : String,
                         request_bytes : Bytes,
                         metadata : GRPC::Metadata) : GRPC::RawServerStream
    ch = ::Channel(Bytes?).new(1)
    ch.close
    GRPC::RawServerStream.new(ch, -> { GRPC::Status.ok })
  end

  def open_bidi_stream_live(service : String, method : String,
                            metadata : GRPC::Metadata,
                            send_queue_size : Int32) : GRPC::RawBidiCall
    ch = ::Channel(Bytes?).new(1)
    ch.close
    GRPC::RawBidiCall.new(
      ->(_b : Bytes) { },
      -> { },
      ch,
      -> { GRPC::Metadata.new },
      -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new },
      -> { }
    )
  end

  def open_client_stream_live(service : String, method : String,
                              metadata : GRPC::Metadata,
                              send_queue_size : Int32) : GRPC::RawClientCall
    GRPC::RawClientCall.new(
      ->(_b : Bytes) { },
      -> { Bytes.empty },
      -> { GRPC::Metadata.new },
      -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new },
      -> { }
    )
  end

  def closed? : Bool
    @closed
  end

  def close : Nil
    @closed = true
  end
end

class BlockingUnaryTransport
  include GRPC::Transport::ClientTransport

  getter started : ::Channel(Nil)
  getter releases : ::Channel(Nil)

  def initialize
    @started = ::Channel(Nil).new(8)
    @releases = ::Channel(Nil).new(8)
  end

  def unary_call(service : String, method : String,
                 request_body : Bytes, metadata : GRPC::Metadata) : GRPC::ResponseEnvelope
    @started.send(nil)
    @releases.receive
    GRPC::ResponseEnvelope.new(
      GRPC::CallInfo.new("/#{service}/#{method}", GRPC::RPCKind::Unary),
      request_body,
      GRPC::Status.ok
    )
  end

  def open_server_stream(service : String, method : String,
                         request_bytes : Bytes,
                         metadata : GRPC::Metadata) : GRPC::RawServerStream
    ch = ::Channel(Bytes?).new(1)
    ch.close
    GRPC::RawServerStream.new(ch, -> { GRPC::Status.ok })
  end

  def open_bidi_stream_live(service : String, method : String,
                            metadata : GRPC::Metadata,
                            send_queue_size : Int32) : GRPC::RawBidiCall
    ch = ::Channel(Bytes?).new(1)
    ch.close
    GRPC::RawBidiCall.new(
      ->(_b : Bytes) { },
      -> { },
      ch,
      -> { GRPC::Metadata.new },
      -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new },
      -> { }
    )
  end

  def open_client_stream_live(service : String, method : String,
                              metadata : GRPC::Metadata,
                              send_queue_size : Int32) : GRPC::RawClientCall
    GRPC::RawClientCall.new(
      ->(_b : Bytes) { },
      -> { Bytes.empty },
      -> { GRPC::Metadata.new },
      -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new },
      -> { }
    )
  end

  def closed? : Bool
    false
  end

  def close : Nil
  end
end

class TimestampUnaryTransport
  include GRPC::Transport::ClientTransport

  getter starts : Array(Time::Instant)

  def initialize
    @starts = [] of Time::Instant
  end

  def unary_call(service : String, method : String,
                 request_body : Bytes, metadata : GRPC::Metadata) : GRPC::ResponseEnvelope
    @starts << Time.instant
    GRPC::ResponseEnvelope.new(
      GRPC::CallInfo.new("/#{service}/#{method}", GRPC::RPCKind::Unary),
      request_body,
      GRPC::Status.ok
    )
  end

  def open_server_stream(service : String, method : String,
                         request_bytes : Bytes,
                         metadata : GRPC::Metadata) : GRPC::RawServerStream
    ch = ::Channel(Bytes?).new(1)
    ch.close
    GRPC::RawServerStream.new(ch, -> { GRPC::Status.ok })
  end

  def open_bidi_stream_live(service : String, method : String,
                            metadata : GRPC::Metadata,
                            send_queue_size : Int32) : GRPC::RawBidiCall
    ch = ::Channel(Bytes?).new(1)
    ch.close
    GRPC::RawBidiCall.new(
      ->(_b : Bytes) { },
      -> { },
      ch,
      -> { GRPC::Metadata.new },
      -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new },
      -> { }
    )
  end

  def open_client_stream_live(service : String, method : String,
                              metadata : GRPC::Metadata,
                              send_queue_size : Int32) : GRPC::RawClientCall
    GRPC::RawClientCall.new(
      ->(_b : Bytes) { },
      -> { Bytes.empty },
      -> { GRPC::Metadata.new },
      -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new },
      -> { }
    )
  end

  def closed? : Bool
    false
  end

  def close : Nil
  end
end

class BlockingServerStreamTransport
  include GRPC::Transport::ClientTransport

  getter started : ::Channel(Nil)

  def initialize
    @started = ::Channel(Nil).new(8)
  end

  def unary_call(service : String, method : String,
                 request_body : Bytes, metadata : GRPC::Metadata) : GRPC::ResponseEnvelope
    GRPC::ResponseEnvelope.new(
      GRPC::CallInfo.new("/#{service}/#{method}", GRPC::RPCKind::Unary),
      request_body,
      GRPC::Status.ok
    )
  end

  def open_server_stream(service : String, method : String,
                         request_bytes : Bytes,
                         metadata : GRPC::Metadata) : GRPC::RawServerStream
    @started.send(nil)
    ch = ::Channel(Bytes?).new(1)
    GRPC::RawServerStream.new(ch, -> { GRPC::Status.ok }, -> { GRPC::Metadata.new }, -> { ch.close; nil })
  end

  def open_bidi_stream_live(service : String, method : String,
                            metadata : GRPC::Metadata,
                            send_queue_size : Int32) : GRPC::RawBidiCall
    ch = ::Channel(Bytes?).new(1)
    ch.close
    GRPC::RawBidiCall.new(
      ->(_b : Bytes) { },
      -> { },
      ch,
      -> { GRPC::Metadata.new },
      -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new },
      -> { }
    )
  end

  def open_client_stream_live(service : String, method : String,
                              metadata : GRPC::Metadata,
                              send_queue_size : Int32) : GRPC::RawClientCall
    GRPC::RawClientCall.new(
      ->(_b : Bytes) { },
      -> { Bytes.empty },
      -> { GRPC::Metadata.new },
      -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new },
      -> { }
    )
  end

  def closed? : Bool
    false
  end

  def close : Nil
  end
end

class CyclingClientTransport
  include GRPC::Transport::ClientTransport

  getter id : Int32

  def initialize(@id : Int32)
    @closed = false
  end

  def unary_call(service : String, method : String,
                 request_body : Bytes, metadata : GRPC::Metadata) : GRPC::ResponseEnvelope
    GRPC::ResponseEnvelope.new(
      GRPC::CallInfo.new("/#{service}/#{method}", GRPC::RPCKind::Unary),
      Bytes[@id.to_u8],
      GRPC::Status.ok
    )
  end

  def open_server_stream(service : String, method : String,
                         request_bytes : Bytes,
                         metadata : GRPC::Metadata) : GRPC::RawServerStream
    ch = ::Channel(Bytes?).new(1)
    ch.close
    GRPC::RawServerStream.new(ch, -> { GRPC::Status.ok })
  end

  def open_bidi_stream_live(service : String, method : String,
                            metadata : GRPC::Metadata,
                            send_queue_size : Int32) : GRPC::RawBidiCall
    ch = ::Channel(Bytes?).new(1)
    ch.close
    GRPC::RawBidiCall.new(
      ->(_b : Bytes) { },
      -> { },
      ch,
      -> { GRPC::Metadata.new },
      -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new },
      -> { }
    )
  end

  def open_client_stream_live(service : String, method : String,
                              metadata : GRPC::Metadata,
                              send_queue_size : Int32) : GRPC::RawClientCall
    GRPC::RawClientCall.new(
      ->(_b : Bytes) { },
      -> { Bytes.empty },
      -> { GRPC::Metadata.new },
      -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new },
      -> { }
    )
  end

  def closed? : Bool
    @closed
  end

  def close : Nil
    @closed = true
  end
end

class FailingClientInterceptor < GRPC::ClientInterceptor
  def call(request : GRPC::RequestEnvelope,
           ctx : GRPC::ClientContext,
           next_call : GRPC::UnaryClientCall) : GRPC::ResponseEnvelope
    raise GRPC::StatusError.new(GRPC::StatusCode::INTERNAL, "interceptor exploded")
  end
end

class FakeServerTransport
  include GRPC::Transport::ServerTransport

  @closed = false

  def initialize(@started : ::Channel(Nil))
  end

  def run_recv_loop : Nil
    @started.send(nil)
  end

  def closed? : Bool
    @closed
  end

  def close : Nil
    @closed = true
  end
end

class BlockingServerTransport
  include GRPC::Transport::ServerTransport

  getter started : ::Channel(Nil)
  getter closed_signal : ::Channel(Nil)

  def initialize
    @started = ::Channel(Nil).new(1)
    @closed_signal = ::Channel(Nil).new(1)
    @released = ::Channel(Nil).new(1)
    @closed = Atomic(Bool).new(false)
  end

  def run_recv_loop : Nil
    @started.send(nil)
    @released.receive
  end

  def closed? : Bool
    @closed.get
  end

  def close : Nil
    return unless @closed.compare_and_set(false, true)[1]
    @released.send(nil)
    @closed_signal.send(nil)
  end
end
