require "socket"

MISSING_GRPCURL_MSG = "grpcurl is not installed; skipping e2e tests"

def grpcurl_available? : Bool
  status = Process.run(
    "grpcurl",
    ["-version"],
    output: Process::Redirect::Close,
    error: Process::Redirect::Close,
  )
  status.success?
rescue
  false
end

module E2EProto
  def self.encode_string(value : String) : Bytes
    io = IO::Memory.new
    tag = (1 << 3) | 2 # field 1, wire type 2
    encode_varint(io, tag.to_u64)
    encode_varint(io, value.bytesize.to_u64)
    io.write(value.to_slice)
    io.to_slice
  end

  def self.decode_string(data : Bytes) : String
    return "" if data.empty?
    i = 0
    while i < data.size
      tag, consumed = decode_varint(data, i)
      i += consumed
      wire_type = (tag & 0x7).to_i
      field_number = (tag >> 3).to_i
      case wire_type
      when 2
        len, consumed = decode_varint(data, i)
        i += consumed
        return String.new(data[i, len.to_i]) if field_number == 1
        i += len.to_i
      when 0
        _, consumed = decode_varint(data, i)
        i += consumed
      else
        break
      end
    end
    ""
  end

  private def self.encode_varint(io : IO, value : UInt64) : Nil
    loop do
      byte = (value & 0x7F).to_u8
      value >>= 7
      io.write_byte(value != 0 ? (byte | 0x80_u8) : byte)
      break if value == 0
    end
  end

  private def self.decode_varint(data : Bytes, offset : Int32) : {UInt64, Int32}
    result = 0_u64
    shift = 0
    i = 0
    loop do
      break if offset + i >= data.size
      byte = data[offset + i].to_u64
      i += 1
      result |= (byte & 0x7F) << shift
      shift += 7
      break unless (byte & 0x80) != 0
    end
    {result, i}
  end
end

class E2EProbeService < GRPC::Service
  SERVICE_NAME = "e2e.Probe"

  def service_name : String
    SERVICE_NAME
  end

  def dispatch(
    method : String,
    request_body : Bytes,
    ctx : GRPC::ServerContext,
  ) : {Bytes, GRPC::Status}
    input = E2EProto.decode_string(request_body)

    case method
    when "UnaryEcho"
      token = ctx.metadata["x-e2e-token"]? || "none"
      output = E2EProto.encode_string("echo:#{input};token:#{token}")
      {output, GRPC::Status.ok}
    when "UnaryFail"
      {Bytes.empty, GRPC::Status.new(GRPC::StatusCode::NOT_FOUND, "missing:#{input}")}
    when "SlowUnary"
      sleep 300.milliseconds
      {E2EProto.encode_string("slow:#{input}"), GRPC::Status.ok}
    else
      {Bytes.empty, GRPC::Status.unimplemented("unknown method")}
    end
  end

  def server_streaming?(method : String) : Bool
    method == "ServerStream"
  end

  def dispatch_server_stream(
    method : String,
    request_body : Bytes,
    ctx : GRPC::ServerContext,
    writer : GRPC::RawResponseStream,
  ) : GRPC::Status
    case method
    when "ServerStream"
      input = E2EProto.decode_string(request_body)
      3.times do |i|
        writer.send_raw(E2EProto.encode_string("stream:#{i}:#{input}"))
      end
      GRPC::Status.ok
    else
      GRPC::Status.unimplemented("unknown method")
    end
  end

  def client_streaming?(method : String) : Bool
    method == "ClientStream"
  end

  def dispatch_client_stream(
    method : String,
    requests : GRPC::RawRequestStream,
    ctx : GRPC::ServerContext,
  ) : {Bytes, GRPC::Status}
    case method
    when "ClientStream"
      parts = [] of String
      requests.each { |body| parts << E2EProto.decode_string(body) }
      body = E2EProto.encode_string("joined:#{parts.join(",")}")
      {body, GRPC::Status.ok}
    else
      {Bytes.empty, GRPC::Status.unimplemented("unknown method")}
    end
  end

  def bidi_streaming?(method : String) : Bool
    method == "BidiStream"
  end

  def dispatch_bidi_stream(
    method : String,
    requests : GRPC::RawRequestStream,
    ctx : GRPC::ServerContext,
    writer : GRPC::RawResponseStream,
  ) : GRPC::Status
    case method
    when "BidiStream"
      idx = 0
      requests.each do |body|
        input = E2EProto.decode_string(body)
        writer.send_raw(E2EProto.encode_string("bidi:#{idx}:#{input}"))
        idx += 1
      end
      GRPC::Status.ok
    else
      GRPC::Status.unimplemented("unknown method")
    end
  end
end

def find_free_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

def wait_for_server(port : Int32, timeout : Time::Span = 2.seconds) : Nil
  deadline = Time.instant + timeout
  loop do
    begin
      socket = TCPSocket.new("127.0.0.1", port)
      socket.close
      return
    rescue
      raise "server did not start listening in time" if Time.instant >= deadline
      sleep 50.milliseconds
    end
  end
end

def run_grpcurl(
  args : Array(String),
) : {Process::Status, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run("grpcurl", args, output: stdout, error: stderr)
  {status, stdout.to_s, stderr.to_s}
end

def grpcurl_base_flags : Array(String)
  proto_dir = File.expand_path("../fixtures/grpcurl", __DIR__)
  [
    "-plaintext",
    "-import-path", proto_dir,
    "-proto", "e2e.proto",
  ]
end

def grpcurl_call_args(
  port : Int32,
  method : String,
  flags : Array(String) = [] of String,
) : Array(String)
  args = grpcurl_base_flags
  args.concat(flags)
  args << "127.0.0.1:#{port}"
  args << method
  args
end

describe "grpcurl e2e baseline" do
  it "invokes unary success and returns expected payload" do
    pending MISSING_GRPCURL_MSG unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      args = grpcurl_call_args(
        port,
        "e2e.Probe/UnaryEcho",
        ["-d", "{\"message\":\"hello\"}"],
      )
      status, out, err = run_grpcurl(args)
      raise "grpcurl failed: #{err}\nstdout: #{out}" unless status.success?
      status.success?.should be_true
      err.should eq("")
      out.should contain("echo:hello")
    ensure
      server.stop
    end
  end

  it "passes rpc-header metadata to server logic" do
    pending MISSING_GRPCURL_MSG unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      args = grpcurl_call_args(
        port,
        "e2e.Probe/UnaryEcho",
        [
          "-rpc-header", "x-e2e-token: abc123",
          "-d", "{\"message\":\"meta\"}",
        ],
      )
      status, out, err = run_grpcurl(args)
      raise "grpcurl failed: #{err}\nstdout: #{out}" unless status.success?
      status.success?.should be_true
      out.should contain("token:abc123")
    ensure
      server.stop
    end
  end

  it "returns grpc status for unary failure" do
    pending MISSING_GRPCURL_MSG unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      args = grpcurl_call_args(
        port,
        "e2e.Probe/UnaryFail",
        ["-d", "{\"message\":\"lost\"}"],
      )
      status, _out, err = run_grpcurl(args)
      raise "expected grpc error but got success" if status.success?
      status.success?.should be_false
      err.downcase.should contain("error")
      err.should contain("missing:lost")
    ensure
      server.stop
    end
  end

  it "enforces max-time timeout for slow unary" do
    pending MISSING_GRPCURL_MSG unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      args = grpcurl_call_args(
        port,
        "e2e.Probe/SlowUnary",
        [
          "-max-time", "0.1",
          "-d", "{\"message\":\"sleep\"}",
        ],
      )
      status, _out, err = run_grpcurl(args)
      raise "expected timeout but got success" if status.success?
      status.success?.should be_false
      lower = err.downcase
      is_timeout = lower.includes?("deadline") ||
                   lower.includes?("timeout") ||
                   lower.includes?("timed out")
      is_timeout.should be_true
    ensure
      server.stop
    end
  end

  it "receives multiple messages from server-streaming call" do
    pending MISSING_GRPCURL_MSG unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      args = grpcurl_call_args(
        port,
        "e2e.Probe/ServerStream",
        ["-d", "{\"message\":\"stream\"}"],
      )
      status, out, err = run_grpcurl(args)
      raise "grpcurl failed: #{err}\nstdout: #{out}" unless status.success?
      out.should contain("stream:0:stream")
      out.should contain("stream:1:stream")
      out.should contain("stream:2:stream")
    ensure
      server.stop
    end
  end

  it "sends multiple messages to client-streaming call" do
    pending MISSING_GRPCURL_MSG unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      payload = %({"message":"a"}\n{"message":"b"}\n{"message":"c"})
      args = grpcurl_call_args(
        port,
        "e2e.Probe/ClientStream",
        ["-d", payload],
      )
      status, out, err = run_grpcurl(args)
      raise "grpcurl failed: #{err}\nstdout: #{out}" unless status.success?
      out.should contain("joined:a,b,c")
    ensure
      server.stop
    end
  end

  it "exchanges messages in bidirectional streaming call" do
    pending MISSING_GRPCURL_MSG unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      payload = %({"message":"x"}\n{"message":"y"})
      args = grpcurl_call_args(
        port,
        "e2e.Probe/BidiStream",
        ["-d", payload],
      )
      status, out, err = run_grpcurl(args)
      raise "grpcurl failed: #{err}\nstdout: #{out}" unless status.success?
      out.should contain("bidi:0:x")
      out.should contain("bidi:1:y")
    ensure
      server.stop
    end
  end
end
