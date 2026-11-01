require "./spec_helper"

private def frame_header(flag : UInt8, length : UInt32) : Bytes
  io = IO::Memory.new
  io.write_byte(flag)
  io.write_bytes(length, IO::ByteFormat::BigEndian)
  io.to_slice
end

# Deliberately bypass response framing to exercise malformed peer data through
# real nghttp2 callbacks. This hook exists only in the spec executable.
class GRPC::RawResponseStream
  def send_frame_for_validation_spec(frame : Bytes) : Nil
    @send_proc.call(frame)
  end
end

class MalformedFrameConnection < GRPC::Transport::Http2ServerConnection
  private def build_initial_headers(metadata : GRPC::Metadata) : Array(LibNghttp2::Nv)
    headers = super(metadata)
    # Production responses are uncompressed. This test peer advertises gzip
    # so corrupt compressed DATA reaches the decompressor under valid headers.
    if encoding = metadata.get("grpc-encoding")
      headers << make_nv("grpc-encoding", encoding)
    end
    headers
  end
end

class MalformedFrameService < GRPC::Service
  def service_full_name : String
    "test.MalformedFrame"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {request_body, GRPC::Status.ok}
  end

  def server_streaming?(method : String) : Bool
    method != "Echo"
  end

  def dispatch_server_stream(method : String, request_body : Bytes,
                             ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    frame = case method
            when "Length" then frame_header(0_u8, 0xffffffff_u32)
            when "Flag"   then frame_header(2_u8, 1000_u32)
            else
              ctx.initial_metadata.add("grpc-encoding", "gzip")
              frame_header(1_u8, 3_u32) + Bytes[1, 2, 3]
            end
    writer.send_frame_for_validation_spec(frame)
    GRPC::Status.ok
  end
end

describe "malformed streamed responses over HTTP/2" do
  {"Length" => GRPC::StatusCode::RESOURCE_EXHAUSTED,
   "Flag"   => GRPC::StatusCode::UNIMPLEMENTED,
   "Gzip"   => GRPC::StatusCode::INTERNAL}.each do |method, expected|
    it "isolates #{method} errors while leaving the connection usable" do
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.local_address.port
      listener.close
      factory = ->(io : IO, services : Hash(String, GRPC::Service), interceptors : Array(GRPC::ServerInterceptor), peer : String, tls : OpenSSL::SSL::Socket::Server?) {
        MalformedFrameConnection.new(io, services, interceptors, peer, tls).as(GRPC::Transport::ServerTransport)
      }
      server = GRPC::Server.new(transport_factory: factory)
      server.handle(MalformedFrameService.new)
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")
      context = GRPC::ClientContext.new(deadline: Time.utc + 5.seconds)
      stream = channel.open_server_stream("test.MalformedFrame", method, Bytes.empty, context)
      stream.each { |_message| fail "malformed peer emitted a valid message" }
      stream.status.code.should eq(expected)
      reply = channel.unary_call("test.MalformedFrame", "Echo", Bytes[7], context)
      reply.status.ok?.should be_true
      reply.raw.should eq(Bytes[7])
    ensure
      channel.try(&.close)
      server.try(&.stop)
    end
  end
end

describe "gRPC frame header validation" do
  [0x7ffffffb_u32, 0x80000000_u32, 0xffffffff_u32].each do |length|
    it "rejects unrepresentable length #{length} consistently before reading its payload" do
      header = frame_header(0_u8, length)
      error = expect_raises(GRPC::StatusError) { GRPC::Codec.decode(header) }
      error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      deframer = GRPC::Transport::GrpcDeframer.new
      header.each do |byte|
        deframer.append(Bytes[byte])
        next if deframer.remainder_size < GRPC::Codec::HEADER_SIZE
        error = expect_raises(GRPC::StatusError) { deframer.drain_messages }
        error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      end
      stream = GRPC::Transport::PendingStream.new
      stream.receive_data(header)
      stream.messages.receive?.should be_nil
      stream.grpc_status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
    end
  end

  it "rejects an unsupported compression flag without waiting for the payload" do
    header = frame_header(2_u8, 1000_u32)
    deframer = GRPC::Transport::GrpcDeframer.new
    deframer.append(header)
    error = expect_raises(GRPC::StatusError) { deframer.drain_messages }
    error.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
  end

  it "keeps a representable incomplete frame pending rather than inventing a message" do
    deframer = GRPC::Transport::GrpcDeframer.new
    deframer.append(frame_header(0_u8, 0x7ffffffa_u32))
    deframer.drain_messages.should be_empty
    deframer.remainder_size.should eq(5)
  end

  [Bytes.empty, Bytes[1, 2, 3]].each do |payload|
    it "converts invalid gzip payload #{payload} into a stream status" do
      wire = IO::Memory.new
      wire.write(frame_header(1_u8, payload.size.to_u32))
      wire.write(payload)
      error = expect_raises(GRPC::StatusError) { GRPC::Codec.decode(wire.to_slice, "gzip", validate_encoding: true) }
      error.code.should eq(GRPC::StatusCode::INTERNAL)
      stream = GRPC::Transport::PendingStream.new
      stream.add_header("grpc-encoding", "gzip")
      stream.receive_data(wire.to_slice)
      stream.messages.receive?.should be_nil
      stream.grpc_status.code.should eq(GRPC::StatusCode::INTERNAL)
    end
  end

  it "rejects a corrupt gzip trailer as a stream error" do
    wire = GRPC::Codec.encode("checksum".to_slice, compress: true)
    wire[-1] = wire[-1] ^ 0xff_u8
    stream = GRPC::Transport::PendingStream.new
    stream.add_header("grpc-encoding", "gzip")
    stream.receive_data(wire)
    stream.messages.receive?.should be_nil
    stream.grpc_status.code.should eq(GRPC::StatusCode::INTERNAL)
  end

  it "still accepts a valid gzip member containing an empty message" do
    wire = GRPC::Codec.encode(Bytes.empty, compress: true)
    GRPC::Codec.decode(wire, "gzip", validate_encoding: true)[0].should be_empty
  end

  ["data", "header"].each do |source|
    it "resets a malformed #{source} stream after releasing the connection callback lock" do
      stream = GRPC::Transport::PendingStream.new
      connection_lock = Mutex.new
      cancelled = Channel(Nil).new(1)
      stream.cancel_proc = -> {
        connection_lock.synchronize { cancelled.send(nil) }
        nil
      }
      connection_lock.synchronize do
        if source == "header"
          stream.add_header("grpc-encoding", "unsupported")
        else
          stream.receive_data(frame_header(2_u8, 0_u32))
        end
      end
      select
      when cancelled.receive
      when timeout(1.second)
        fail "malformed stream was not reset outside the connection callback"
      end
      stream.grpc_status.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
    end
  end
end
