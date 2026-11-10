module GRPC
  module Transport
    # ClientTransport is the interface that Channel depends on.
    # Concrete implementations (Http2ClientConnection) include this module.
    # All methods return public stream types; PendingStream stays internal.
    module ClientTransport
      abstract def unary_call(service : String, method : String,
                              request_body : Bytes, metadata : Metadata) : ResponseEnvelope

      # Custom transports may override the context-aware overloads to observe
      # cancellation after submission. Existing transports remain compatible.
      def unary_call(service : String, method : String,
                     request_body : Bytes, ctx : ClientContext) : ResponseEnvelope
        unary_call(service, method, request_body, ctx.effective_metadata)
      end

      abstract def open_server_stream(service : String, method : String,
                                      request_bytes : Bytes,
                                      metadata : Metadata) : RawServerStream

      def open_server_stream(service : String, method : String,
                             request_bytes : Bytes, ctx : ClientContext) : RawServerStream
        open_server_stream(service, method, request_bytes, ctx.effective_metadata)
      end

      abstract def open_bidi_stream_live(service : String, method : String,
                                         metadata : Metadata,
                                         send_queue_size : Int32) : RawBidiCall

      def open_bidi_stream_live(service : String, method : String,
                                ctx : ClientContext, send_queue_size : Int32) : RawBidiCall
        open_bidi_stream_live(service, method, ctx.effective_metadata, send_queue_size)
      end

      abstract def open_client_stream_live(service : String, method : String,
                                           metadata : Metadata,
                                           send_queue_size : Int32) : RawClientCall

      def open_client_stream_live(service : String, method : String,
                                  ctx : ClientContext, send_queue_size : Int32) : RawClientCall
        open_client_stream_live(service, method, ctx.effective_metadata, send_queue_size)
      end

      abstract def closed? : Bool

      # Draining transports may still serve accepted RPCs.
      def accepting_new_calls? : Bool
        !closed?
      end

      abstract def close : Nil
    end

    # ServerTransport is the interface that Server depends on.
    # Concrete implementations (Http2ServerConnection) include this module.
    module ServerTransport
      abstract def run_recv_loop : Nil
      abstract def closed? : Bool
      abstract def close : Nil
    end
  end
end
