require "./integration_services"

class RecordingClientInterceptor < GRPC::ClientInterceptor
  getter calls : Array(String) = [] of String

  def call(
    request : GRPC::RequestEnvelope,
    ctx : GRPC::ClientContext,
    next_call : GRPC::UnaryClientCall,
  ) : GRPC::ResponseEnvelope
    @calls << "before:#{request.info.method_path}"
    result = next_call.call(request.info.method_path, request, ctx)
    @calls << "after:#{request.info.method_path}"
    result
  end
end

class MutatingClientInterceptor < GRPC::ClientInterceptor
  def call(
    request : GRPC::RequestEnvelope,
    ctx : GRPC::ClientContext,
    next_call : GRPC::UnaryClientCall,
  ) : GRPC::ResponseEnvelope
    # Inject a header before the call.
    merged = ctx.metadata.dup
    merged.set("x-from-interceptor", "1")
    new_ctx = GRPC::ClientContext.new(metadata: merged)
    next_call.call(request.info.method_path, request, new_ctx)
  end
end

class AuthServerInterceptor < GRPC::ServerInterceptor
  def call(
    request : GRPC::RequestEnvelope,
    ctx : GRPC::ServerContext,
    next_call : GRPC::UnaryServerCall,
  ) : GRPC::ResponseEnvelope
    unless ctx.metadata["authorization"]? == "valid-token"
      return GRPC::ResponseEnvelope.new(
        request.info,
        Bytes.empty,
        GRPC::Status.new(GRPC::StatusCode::UNAUTHENTICATED, "invalid token")
      )
    end
    next_call.call(request.info.method_path, request, ctx)
  end
end

class RecordingServerInterceptor < GRPC::ServerInterceptor
  getter calls : Array(String) = [] of String

  def call(
    request : GRPC::RequestEnvelope,
    ctx : GRPC::ServerContext,
    next_call : GRPC::UnaryServerCall,
  ) : GRPC::ResponseEnvelope
    @calls << "before:#{request.info.method}"
    result = next_call.call(request.info.method_path, request, ctx)
    @calls << "after:#{request.info.method}"
    result
  end
end

class InitialMetadataServerInterceptor < GRPC::ServerInterceptor
  def call(
    request : GRPC::RequestEnvelope,
    ctx : GRPC::ServerContext,
    next_call : GRPC::UnaryServerCall,
  ) : GRPC::ResponseEnvelope
    response = next_call.call(request.info.method_path, request, ctx)
    initial = response.initial_metadata.dup
    initial.add("x-interceptor-initial", "unary")
    GRPC::ResponseEnvelope.new(response.info, response.raw, response.status,
      initial, response.trailing_metadata, response.codec, response.descriptor)
  end

  def call_server_stream(
    request : GRPC::RequestEnvelope,
    ctx : GRPC::ServerContext,
    writer : GRPC::RawResponseStream,
    next_call : GRPC::ServerStreamServerCall,
  ) : GRPC::Status
    ctx.initial_metadata.add("x-interceptor-initial", "stream")
    next_call.call(request.info.method_path, request, ctx, writer)
  end
end

# Records calls for all four RPC variants.
class FullRecordingServerInterceptor < GRPC::ServerInterceptor
  getter calls : Array(String) = [] of String

  def call(
    request : GRPC::RequestEnvelope,
    ctx : GRPC::ServerContext,
    next_call : GRPC::UnaryServerCall,
  ) : GRPC::ResponseEnvelope
    @calls << "unary:before:#{request.info.method}"
    result = next_call.call(request.info.method_path, request, ctx)
    @calls << "unary:after:#{request.info.method}"
    result
  end

  def call_server_stream(
    request : GRPC::RequestEnvelope,
    ctx : GRPC::ServerContext,
    writer : GRPC::RawResponseStream,
    next_call : GRPC::ServerStreamServerCall,
  ) : GRPC::Status
    @calls << "ss:before:#{request.info.method}"
    status = next_call.call(request.info.method_path, request, ctx, writer)
    @calls << "ss:after:#{request.info.method}"
    status
  end

  def call_client_stream(
    info : GRPC::CallInfo,
    requests : GRPC::RawRequestStream,
    ctx : GRPC::ServerContext,
    next_call : GRPC::ClientStreamServerCall,
  ) : GRPC::ResponseEnvelope
    @calls << "cs:before:#{info.method}"
    result = next_call.call(info.method_path, requests, ctx)
    @calls << "cs:after:#{info.method}"
    result
  end

  def call_bidi_stream(
    info : GRPC::CallInfo,
    requests : GRPC::RawRequestStream,
    ctx : GRPC::ServerContext,
    writer : GRPC::RawResponseStream,
    next_call : GRPC::BidiStreamServerCall,
  ) : GRPC::Status
    @calls << "bidi:before:#{info.method}"
    status = next_call.call(info.method_path, requests, ctx, writer)
    @calls << "bidi:after:#{info.method}"
    status
  end
end

class FullRecordingClientInterceptor < GRPC::ClientInterceptor
  getter calls : Array(String) = [] of String

  def call(
    request : GRPC::RequestEnvelope,
    ctx : GRPC::ClientContext,
    next_call : GRPC::UnaryClientCall,
  ) : GRPC::ResponseEnvelope
    @calls << "unary:before:#{request.info.method_path}"
    result = next_call.call(request.info.method_path, request, ctx)
    @calls << "unary:after:#{request.info.method_path}"
    result
  end

  def call_server_stream(
    request : GRPC::RequestEnvelope,
    ctx : GRPC::ClientContext,
    next_call : GRPC::ServerStreamClientCall,
  ) : GRPC::RawServerStream
    @calls << "ss:before:#{request.info.method_path}"
    stream = next_call.call(request.info.method_path, request, ctx)
    @calls << "ss:after:#{request.info.method_path}"
    stream
  end

  def call_live_client_stream(
    info : GRPC::CallInfo,
    ctx : GRPC::ClientContext,
    next_call : GRPC::LiveClientStreamClientCall,
  ) : GRPC::RawClientCall
    @calls << "cs:before:#{info.method_path}"
    result = next_call.call(info.method_path, ctx)
    @calls << "cs:after:#{info.method_path}"
    result
  end

  def call_live_bidi_stream(
    info : GRPC::CallInfo,
    ctx : GRPC::ClientContext,
    next_call : GRPC::LiveBidiStreamClientCall,
  ) : GRPC::RawBidiCall
    @calls << "bidi:before:#{info.method_path}"
    stream = next_call.call(info.method_path, ctx)
    @calls << "bidi:after:#{info.method_path}"
    stream
  end
end
