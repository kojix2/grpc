# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Native Crystal gRPC library built directly on **libnghttp2** via FFI. Library sources live in `src/grpc/` and examples in `examples/`. Low-level HTTP/2 details are internal; the public API is Crystal.

## Commands

```bash
# Run tests (from grpc/)
crystal spec

# Run a single spec file
crystal spec spec/api/codec_spec.cr

# Build the protoc plugin
crystal build src/protoc-gen-crystal-grpc_main.cr -o bin/protoc-gen-crystal-grpc

# Generate gRPC stubs from a .proto file
protoc --plugin=protoc-gen-crystal-grpc=bin/protoc-gen-crystal-grpc \
       --crystal-grpc_out=OUTPUT_DIR \
       path/to/service.proto

# Run examples
crystal run examples/helloworld/server.cr
crystal run examples/helloworld/client.cr -- localhost 50051 Alice

# Format code
crystal tool format

# Lint
ameba
```

## System Dependencies

- `libnghttp2` — HTTP/2 library (Arch: `pacman -S nghttp2`, Debian: `apt install libnghttp2-dev`, macOS: `brew install nghttp2`)
- Crystal >= 1.19.1

## Architecture

```
Public API (server.cr, channel.cr, stream.cr, interceptor.cr)
    ↓
Service abstraction (service_handler.cr, call_context.cr, metadata.cr, codec.cr)
    ↓
Transport layer (transport/http2_connection.cr, http2_server_connection.cr, http2_client_connection.cr)
    ↓
libnghttp2 FFI (transport/lib_nghttp2.cr)
    ↓
Crystal stdlib TCPSocket
```

### Transport Layer

- **`http2_connection.cr`** — Base class wrapping an nghttp2 session. Sets up C callbacks (on_begin_headers, on_header, on_data_chunk, on_frame_recv, on_stream_close) that delegate to Crystal methods. Manages `StreamData` accumulation and a `SendBuffer` for outgoing bytes.
- **`http2_server_connection.cr`** — Handles inbound connections. Unary requests dispatch after `END_STREAM`; live client/bidirectional request streams dispatch while DATA arrives. Service handlers and interceptors run outside nghttp2 callbacks; responses use HEADERS + DATA + trailers.
- **`http2_client_connection.cr`** — Manages outbound RPCs via `PendingCall` / `PendingStream`. Submits request HEADERS + DATA, then blocks a Crystal `::Channel` until the response trailers arrive.
- **`lib_nghttp2.cr`** — Thin FFI bindings; declares C structs, enums, and function signatures for libnghttp2.

### Public API Layer

- **`server.cr`** — `GRPC::Server`: registers services, binds TCP, accepts connections (one fiber each), routes to `Http2ServerConnection`.
- **`channel.cr`** — `GRPC::Channel`: creates/reuses `Http2ClientConnection`. Entry point for unary, server-stream, client-stream, and bidi calls. Accepts `tls_context:` for custom TLS settings.
- **`service_handler.cr`** — `GRPC::Service` abstract base class. Generated service stubs inherit this and override `dispatch(method, body, ctx)`.
- **`stream.cr`** — Typed wrappers for streaming RPCs: `ServerStream(T)`, `ClientStream`, `BidiCall`, `ResponseStream`.
- **`codec.cr`** — gRPC message framing: 5-byte header (1 compression flag + 4 length) prefixed to Protobuf bytes.
- **`metadata.cr`** — Case-insensitive, multi-value HTTP header map.
- **`interceptor.cr`** — Middleware chains for all four RPC variants (unary, server-streaming, client-streaming, bidi).  Each variant has its own proc alias and default pass-through method; only override what you need.
- **`call_context.cr`** — `ServerContext` and `ClientContext` carrying peer address, deadline, and metadata.

### protoc-gen-crystal-grpc

`src/protoc-gen-crystal-grpc.cr` is a standalone `protoc` plugin binary.  Given a proto file it emits a `.grpc.cr` file containing an abstract `GRPC::Service` subclass and a typed client stub for every service defined in the file.  All four RPC streaming variants are supported.

The plugin uses the `proto` shard's `Proto::Bootstrap` request/response and
descriptor types, plus its canonical/type-map name resolvers.
`CrystalGrpcCodeGenerator` walks those descriptors and emits Crystal source.

Generated code conventions:
- Service class: `{ServiceName}Service < GRPC::Service`  (e.g. `GreeterService`)
- Client class: `{ServiceName}Client`  (e.g. `GreeterClient`)
- RPC method names: snake_cased  (`SayHello` → `say_hello`)
- Package wrapping: `helloworld` → `module Helloworld`
- Cross-package types: `.google.protobuf.Empty` → `Google::Protobuf::Empty`

### Streaming, compression and receive budgets

- All four RPC shapes are supported. Live client and bidirectional streams send
  requests incrementally; live bidirectional streams support interleaved sends
  and receives before `close_send`.
- Clients can gzip-compress requests and decode gzip responses. Servers decode
  gzip requests; production server responses are currently uncompressed.
- `GRPC::ReceiveLimits` defaults to 64 MiB for each wire message, decoded message
  and per-stream unconsumed decoded backlog. Configure clients through
  `EndpointConfig#receive_limits` and default servers through
  `Server.new(receive_limits: ...)`. Custom transports enforce their own policy.
- Over-budget RPCs finish with `RESOURCE_EXHAUSTED`; do not work around them by
  increasing message-count queues or HTTP/2 windows. Test header-only rejection,
  bounded decompression, backlog accounting and connection reuse.

## nghttp2 Critical Rules

Two hard-won constraints (see memory files for full details):

1. **Never write the HTTP/2 client preface manually.** `nghttp2_session_mem_send` includes it automatically; writing it again corrupts the stream.
2. **`nghttp2_submit_trailer` must be called from inside the data source read callback**, not after `nghttp2_session_send` / `nghttp2_session_mem_send`. Calling it outside kills DATA frames.

## Testing

- `spec/api/` — Public API unit tests, grouped by component and behavior
- `spec/transport/` — Framing, buffering, flow control, and RPC state tests
- `spec/services/` — Health, reflection, and server registration/shutdown
- `spec/generator/` — protoc plugin code-generation tests
- `spec/integration/` — Real HTTP/2 round trips, TLS, deadlines, interceptors, and malformed peers
- `spec/support/` — Explicitly required helpers without examples
- `spec/README.md` — File boundaries, describe/it granularity, reading order, and focused test commands

Keep every spec independently runnable. Order examples from ordinary operation
through boundaries and invalid input to lifecycle checks; do not rely on that
order for execution. Check shuffled execution with `crystal spec --order 20261101`.
