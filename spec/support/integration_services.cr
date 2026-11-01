require "../spec_helper"

module TestProto
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
      else break
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

# A minimal service for testing
class EchoService < GRPC::Service
  SERVICE_FULL_NAME = "test.Echo"

  def service_full_name : String
    SERVICE_FULL_NAME
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    case method
    when "Echo"
      input = TestProto.decode_string(request_body)
      output = TestProto.encode_string("echo:#{input}")
      {output, GRPC::Status.ok}
    when "Fail"
      {Bytes.empty, GRPC::Status.new(GRPC::StatusCode::NOT_FOUND, "not here")}
    else
      {Bytes.empty, GRPC::Status.unimplemented("unknown method")}
    end
  end
end

class StreamingEchoService < GRPC::Service
  SERVICE_FULL_NAME = "test.StreamingEcho"

  def service_full_name : String
    SERVICE_FULL_NAME
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {Bytes.empty, GRPC::Status.unimplemented("unary not implemented")}
  end

  def server_streaming?(method : String) : Bool
    method == "ServerStream" || method == "ErrorStream" || method == "PartialErrorStream"
  end

  def dispatch_server_stream(method : String, request_body : Bytes,
                             ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    case method
    when "ServerStream"
      input = TestProto.decode_string(request_body)
      3.times do |i|
        writer.send_raw(TestProto.encode_string("#{i}:#{input}"))
      end
      GRPC::Status.ok
    when "ErrorStream"
      GRPC::Status.new(GRPC::StatusCode::INTERNAL, "forced stream error")
    when "PartialErrorStream"
      input = TestProto.decode_string(request_body)
      3.times do |i|
        writer.send_raw(TestProto.encode_string("partial#{i}:#{input}"))
      end
      GRPC::Status.new(GRPC::StatusCode::INTERNAL, "forced partial stream error")
    else
      GRPC::Status.unimplemented("unknown method")
    end
  end

  def client_streaming?(method : String) : Bool
    method == "ClientStream"
  end

  def dispatch_client_stream(method : String, requests : GRPC::RawRequestStream,
                             ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    case method
    when "ClientStream"
      parts = [] of String
      requests.each { |body| parts << TestProto.decode_string(body) }
      {TestProto.encode_string("joined:#{parts.join(",")}"), GRPC::Status.ok}
    else
      {Bytes.empty, GRPC::Status.unimplemented("unknown method")}
    end
  end

  def bidi_streaming?(method : String) : Bool
    method == "BidiStream"
  end

  def dispatch_bidi_stream(method : String, requests : GRPC::RawRequestStream,
                           ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    case method
    when "BidiStream"
      idx = 0
      requests.each do |body|
        input = TestProto.decode_string(body)
        writer.send_raw(TestProto.encode_string("reply#{idx}:#{input}"))
        idx += 1
      end
      GRPC::Status.ok
    else
      GRPC::Status.unimplemented("unknown method")
    end
  end
end

class LiveProbeService < GRPC::Service
  SERVICE_FULL_NAME = "test.LiveProbe"

  def initialize(@first_seen : ::Channel(String))
  end

  def service_full_name : String
    SERVICE_FULL_NAME
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {Bytes.empty, GRPC::Status.unimplemented("unary not implemented")}
  end

  def client_streaming?(method : String) : Bool
    method == "ClientStreamLive"
  end

  def dispatch_client_stream(method : String, requests : GRPC::RawRequestStream,
                             ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    case method
    when "ClientStreamLive"
      count = 0
      first = true
      requests.each do |body|
        decoded = TestProto.decode_string(body)
        if first
          @first_seen.send(decoded)
          first = false
        end
        count += 1
      end
      {TestProto.encode_string("count:#{count}"), GRPC::Status.ok}
    else
      {Bytes.empty, GRPC::Status.unimplemented("unknown method")}
    end
  end
end

# Reflects request metadata back to the caller.
# "GetMeta"     — request body encodes the key name; response is that key's value (or "")
# "HasDeadline" — response is "yes" if ctx.deadline is set, "no" otherwise
class MetaEchoService < GRPC::Service
  SERVICE_FULL_NAME = "test.MetaEcho"

  def service_full_name : String
    SERVICE_FULL_NAME
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    case method
    when "GetMeta"
      key = TestProto.decode_string(request_body)
      value = ctx.metadata[key]? || ""
      {TestProto.encode_string(value), GRPC::Status.ok}
    when "HasDeadline"
      {TestProto.encode_string(ctx.deadline.nil? ? "no" : "yes"), GRPC::Status.ok}
    when "InitialMetadata"
      metadata = GRPC::Metadata.new
      metadata.add("x-context-initial", "present")
      ctx.send_initial_metadata(metadata)
      {TestProto.encode_string("ok"), GRPC::Status.ok}
    else
      {Bytes.empty, GRPC::Status.unimplemented("unknown method")}
    end
  end
end

# Used to verify deadline enforcement while handlers are still running.
class DeadlineProbeService < GRPC::Service
  SERVICE_FULL_NAME = "test.DeadlineProbe"

  def service_full_name : String
    SERVICE_FULL_NAME
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    case method
    when "SlowUnary"
      sleep 200.milliseconds
      {TestProto.encode_string("late"), GRPC::Status.ok}
    else
      {Bytes.empty, GRPC::Status.unimplemented("unknown method")}
    end
  end

  def server_streaming?(method : String) : Bool
    method == "SlowServerStream"
  end

  def dispatch_server_stream(method : String, request_body : Bytes,
                             ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    case method
    when "SlowServerStream"
      i = 0
      loop do
        break if ctx.cancelled?
        writer.send_raw(TestProto.encode_string("tick:#{i}"))
        i += 1
        sleep 10.milliseconds
      end
      GRPC::Status.ok
    else
      GRPC::Status.unimplemented("unknown method")
    end
  end
end

# --- Interceptors ---

class FullDuplexEchoService < GRPC::Service
  SERVICE_FULL_NAME = "test.FullDuplexEcho"

  def service_full_name : String
    SERVICE_FULL_NAME
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {Bytes.empty, GRPC::Status.new(GRPC::StatusCode::UNIMPLEMENTED, "unimplemented")}
  end

  def bidi_streaming?(method : String) : Bool
    method == "EchoStream"
  end

  def dispatch_bidi_stream(method : String, requests : GRPC::RawRequestStream,
                           ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    requests.each { |body| writer.send_raw(body) }
    GRPC::Status.ok
  end
end
