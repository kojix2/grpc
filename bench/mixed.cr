# Run with `crystal build --release bench/mixed.cr -o /tmp/grpc-mixed-bench`.
# Emits one JSON object. Run several times on the same host for comparisons.
require "json"
require "../src/grpc"

private class MixedBenchService < GRPC::Service
  def service_full_name : String
    "bench.Mixed"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {request_body, GRPC::Status.ok}
  end

  def bidi_streaming?(method : String) : Bool
    method == "Stream"
  end

  def dispatch_bidi_stream(method : String, requests : GRPC::RawRequestStream,
                           ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    requests.each { |request| writer.send_raw(request) }
    GRPC::Status.ok
  end
end

listener = TCPServer.new("127.0.0.1", 0)
port = listener.local_address.port
listener.close
server = GRPC::Server.new
server.handle(MixedBenchService.new)
server.bind("127.0.0.1:#{port}")
server.start
channel = GRPC::Channel.new("127.0.0.1:#{port}")
begin
  payload = Bytes.new(128 * 1024, 42_u8)
  context = GRPC::ClientContext.new(deadline: 30.seconds)
  stream = channel.open_bidi_stream_live("bench.Mixed", "Stream", context)
  producer = Channel(Exception?).new(1)
  consumer = Channel(Int32 | Exception).new(1)
  allocated_before = GC.stats.total_bytes
  started = Time.instant
  spawn do
    begin
      128.times { stream.send_raw(payload) }
      stream.close_send
      producer.send(nil)
    rescue ex
      producer.send(ex)
    end
  end
  spawn do
    begin
      received = 0
      stream.each do |body|
        raise "bad stream payload" unless body.size == payload.size
        received += 1
      end
      consumer.send(received)
    rescue ex
      consumer.send(ex)
    end
  end

  latencies = [] of Float64
  256.times do
    call_started = Time.instant
    result = channel.unary_call("bench.Mixed", "Echo", Bytes[7], context)
    raise "unary failed: #{result.status}" unless result.status.ok? && result.raw == Bytes[7]
    latencies << (Time.instant - call_started).total_microseconds
  end
  if error = producer.receive
    raise error
  end
  received = consumer.receive
  raise received if received.is_a?(Exception)
  raise "incomplete stream" unless received == 128 && stream.status.ok?
  elapsed = (Time.instant - started).total_seconds
  latencies.sort!
  allocated = GC.stats.total_bytes - allocated_before
  puts({bench: "mixed_bidi_unary", messages: 128, payload_bytes: payload.size,
        unary_calls: latencies.size, p50_us: latencies[127], p95_us: latencies[243],
        p99_us: latencies[253], elapsed_seconds: elapsed,
        allocated_bytes: allocated}.to_json)
ensure
  channel.close
  server.stop
end
