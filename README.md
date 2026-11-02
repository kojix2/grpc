# grpc.cr

[![Test](https://github.com/kojix2/grpc/actions/workflows/test.yml/badge.svg)](https://github.com/kojix2/grpc/actions/workflows/test.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fkojix2%2Fgrpc%2Flines)](https://tokei.kojix2.net/github/kojix2/grpc)

gRPC client/server for Crystal >= 1.19.1, built on libnghttp2 and
[proto.cr](https://github.com/kojix2/proto). Supports all four RPC shapes,
live full-duplex streaming, TLS, metadata, deadlines, interceptors, health and reflection.

## Installation

Install libnghttp2, add the dependency, then run `shards install`:

```sh
sudo apt-get install libnghttp2-dev  # Debian/Ubuntu
# macOS:
brew install libnghttp2
export LIBRARY_PATH="$(brew --prefix libnghttp2)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
```

```yaml
dependencies:
  grpc:
    github: kojix2/grpc
```

## Try it

From this checkout, run the server and client in separate terminals:

```sh
crystal run examples/helloworld/server.cr
crystal run examples/helloworld/client.cr -- localhost 50051 Alice
```

See runnable examples for [streaming](examples/streaming/),
[TLS](examples/tls/) and [interceptors](examples/interceptors/).

## Generate your API

From this checkout, build both plugins; `protoc` must also be installed:

```sh
mkdir -p bin
crystal build lib/proto/src/protoc-gen-crystal_main.cr -o bin/protoc-gen-crystal
shards build
protoc --plugin=protoc-gen-crystal=bin/protoc-gen-crystal \
  --plugin=protoc-gen-crystal-grpc=bin/protoc-gen-crystal-grpc \
  --crystal_out=. --crystal-grpc_out=. path/to/service.proto
```

Replace the schema path with your own. In the consuming application, require
`grpc` first, then the generated `.pb.cr` and `.grpc.cr` files. Unary methods
return the decoded message or raise `GRPC::StatusError`; the corresponding
`*_response` method returns status and metadata. Consume or cancel streams.
If an RPC already uses a helper's name, the generator adds a numeric suffix
to the helper (for example `foo_response_2`). Message types and `type_map`
targets are emitted as absolute Crystal names.

Live bidi calls expose `final_status` (nil until RPC completion, independent of
reply consumption). `SendClosedError` means the message was not enqueued; its
`final_status` is nil for a request half-close. Drain remaining replies on completion.

After GOAWAY, new RPCs use a replacement connection while accepted RPCs finish
on the old connection. Calls are not automatically retried.

TLS configures `h2` ALPN on supplied client and server contexts as well as
default contexts. The client requires the peer to negotiate `h2`.

## Receive limits

`GRPC::ReceiveLimits` defaults to 64 MiB each for wire payload, decoded message
and unconsumed decoded data per stream. Set it through
`EndpointConfig.new(receive_limits: limits)` on clients or
`Server.new(receive_limits: limits)` on default servers.
Excess data ends that RPC with `RESOURCE_EXHAUSTED`; these are not process-wide
RAM limits. Custom transports enforce their own budgets.

Regenerate existing `.grpc.cr` clients to use on-demand typed response decoding.
Responses are decoded when iterated, so unread data stays in the transport's
byte budget.

Clients can send gzip requests and decode gzip responses. Servers decode gzip
requests and currently send uncompressed responses.

## Test

```sh
crystal spec
crystal spec --order 20261102  # replay a shuffled CI run
crystal spec spec/grpcurl.cr  # requires grpcurl
```

CI checks the minimum supported Crystal version and latest Crystal, runs seeded
fragmentation campaigns, regenerates and checks protoc fixtures, and tests the
client against locked and latest grpc-go dependencies over plaintext and TLS.
A separate job regenerates and tests the current MinKNOW client against the
candidate gRPC source. Nightly runs expand fragmentation coverage.

See [test layout](spec/README.md) for focused tests and GripMock setup.
License: [MIT](LICENSE).
