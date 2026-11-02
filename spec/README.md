# Test layout

Read tests from public behavior down to transport details:

| Directory | Responsibility |
| --- | --- |
| `api/` | Status, metadata, endpoints, codecs, contexts, stream wrappers, channel limits |
| `services/` | Health and reflection behavior, including server registration and shutdown |
| `transport/` | Incremental framing, flow control, buffering, RPC state and lifecycle |
| `generator/` | RPC shapes, naming, output options and type resolution |
| `integration/` | Real HTTP/2 calls, TLS, deadlines, interceptors, streaming and malformed peers |
| `support/` | Explicitly required test services, transports, messages and wire helpers; no examples |

Each `*_spec.cr` file loads its own dependencies and can run alone. Do not
require another spec file for its fixtures. External-tool suites retain their
separate entry points, `grpcurl.cr` and `gripmock.cr`, so `crystal spec` does not
silently require grpcurl or a running GripMock server.
The `grpc_go.cr` entry point likewise requires a built grpc-go reference peer
and fails if that peer is missing.

## Adding and ordering examples

- Choose the file by the component and behavior under test. Put regressions
  beside that behavior rather than in a growing `regressions_spec.cr` file.
- Use the class as the outer `describe`, then a method or coherent behavior
  when the class has several responsibilities. Avoid nesting unrelated classes;
  Health and Reflection are separate suites.
- Order groups and examples as initial state and ordinary operation, valid
  boundaries, invalid input, then completion and cancellation. Group RPC shapes
  as unary, server streaming, client streaming, then bidirectional streaming.
- Give each `it` one independently diagnosable outcome. Keep related assertions
  about one result together; split unrelated validation errors or output modes.
  For boundary tables, put `it` inside the loop and include the case in its name.
- Keep unit framing checks separate for Codec, GrpcDeframer and PendingStream;
  a failure at one layer must not prevent checks at another layer from running.
- Keep helpers free of examples and release sockets, servers and streams in
  `ensure` blocks. Execution order must not carry state between examples.

The order above is for reading. File names do not encode execution order, and
the suite must also pass with shuffled examples.

## Commands

```sh
crystal spec
crystal spec spec/transport/pending_stream_spec.cr
crystal spec spec/api spec/transport
crystal spec --order 20261101
crystal spec spec/grpcurl.cr
# With GripMock running as configured in CI:
crystal spec spec/gripmock.cr
crystal tool format --check
```

## Client interoperability

Build the reference peer with Go >= 1.26, then run the suite explicitly:

```sh
mkdir -p bin
(cd spec/interop/go && go build -mod=readonly -o ../../../bin/grpc-go-peer .)
crystal spec spec/grpc_go.cr --order 20261102
```

The peer uses grpc-go v1.85.0 and the official Protobuf wrappers, with module
checksums committed in `spec/interop/go/go.sum`. Crystal clients and messages
are generated from `interop/peer.proto`. Tests cover all four RPC shapes, TLS
with h2 ALPN, gzip in both directions, binary metadata, empty messages, payloads
larger than an HTTP/2 window, Unicode statuses, deadlines and cancellation.
Repeated early bidi completion must free the peer's single concurrency slot.
The TLS fixture disables certificate verification for its local self-signed
certificate; it exercises TLS negotiation, not CA or hostname verification.

This is client-focused. It does not claim official full gRPC conformance,
server interoperability, real-device MinKNOW compatibility or multithreaded
transport support.

## Seeded framing campaigns and CI replay

The default suite includes 32 deterministic message-fragmentation seeds. Each
seed generates binary messages, mixes compressed and uncompressed frames,
splits the wire stream at random boundaries and reuses input storage. The
oracle is the exact original message sequence. It is not a network simulation.

```sh
GRPC_FUZZ_FIRST_SEED=20261102 GRPC_FUZZ_SEEDS=500 \
  crystal spec spec/transport/deframer_fragmentation_spec.cr
```

CI sets the first framing seed and the spec ordering seed from `github.run_id`.
Both are visible in the workflow and failures name
their framing seed. Use those values to reproduce the run. Nightly campaigns
expand to 500 seeds; job timeouts bound hangs and JUnit artifacts preserve
unit and grpc-go results.

`script/check_generated.sh` rebuilds both protoc plugins, regenerates the
collision and interop fixtures and fails on changes or new generated files.
Run `bash script/check_generated.sh --write` when intentionally refreshing
fixtures. The normal CI suite actually calls all four generated RPC methods,
so code-generation checks cover Crystal's lazily instantiated method bodies.

The MinKNOW job checks a pinned consumer commit with a local shard override
pointing at this checkout, runs `make gen`, checks generation drift, runs its
specs and type-checks every example. Update that pin deliberately when adopting
a new consumer/schema fixture. No MinKNOW device is contacted.

Engineering references:

- [dev-transparent/grpc CI at 09b3c7e](https://github.com/dev-transparent/grpc/blob/09b3c7e821bd6c53853424a75acd87abe88d187f/.github/workflows/ci.yml): separate interop and seeded campaigns, bounded jobs, failure artifacts.
- [grpc-go reset handling](https://github.com/grpc/grpc-go/blob/bc90736a6fadc41582f9a23fb955bb66088f1bb8/internal/transport/http2_client.go): classify peer cancellation after the call deadline as `DEADLINE_EXCEEDED`.
- [gRPC HTTP/2 protocol](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md): framing, metadata, compression and stream termination.
