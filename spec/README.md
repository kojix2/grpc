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
