require "../spec_helper"
require "./frame_helpers"

# Deliberately bypass response framing to exercise malformed peer data through
# real nghttp2 callbacks. This hook exists only in the spec executable.
class GRPC::RawResponseStream
  def send_frame_for_validation_spec(frame : Bytes) : Nil
    @send_proc.call(frame)
  end
end

class MalformedFrameConnection < GRPC::Transport::Http2ServerConnection
  private def build_initial_headers(metadata : GRPC::Metadata, compress : Bool = false) : Array(LibNghttp2::Nv)
    headers = super(metadata, compress)
    # Advertise manually constructed gzip DATA even when ordinary server
    # response compression is disabled.
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
            when "Length" then GrpcFrameSpec.frame_header(0_u8, 0xffffffff_u32)
            when "Flag"   then GrpcFrameSpec.frame_header(2_u8, 1000_u32)
            else
              ctx.initial_metadata.add("grpc-encoding", "gzip")
              GrpcFrameSpec.frame_header(1_u8, 3_u32) + Bytes[1, 2, 3]
            end
    writer.send_frame_for_validation_spec(frame)
    GRPC::Status.ok
  end
end
