require "./spec_helper"

describe GRPC::Transport::FlowControlledBuffer do
  it "credits coalesced messages only after the application receives them" do
    credits = [] of Int32
    buffer = GRPC::Transport::FlowControlledBuffer.new(->(bytes : Int32) { credits << bytes; nil })
    wire = IO::Memory.new
    512.times { |i| wire.write(GRPC::Codec.encode(i.to_s.to_slice)) }
    buffer.append(wire.to_slice).should eq(0)
    Fiber.yield
    credits.should be_empty
    buffer.finish
    512.times { |i| String.new(buffer.messages.receive.not_nil!).should eq(i.to_s) }
    buffer.messages.receive?.should be_nil
    credits.sum.should eq(wire.size)
  ensure
    buffer.try(&.close)
  end

  it "releases partial-frame credit after a preceding message is consumed" do
    credits = [] of Int32
    buffer = GRPC::Transport::FlowControlledBuffer.new(->(bytes : Int32) { credits << bytes; nil })
    first = GRPC::Codec.encode(Bytes[1])
    second = GRPC::Codec.encode(Bytes[2, 3, 4])
    wire = IO::Memory.new
    wire.write(first)
    wire.write(second[0, 6])
    buffer.append(wire.to_slice).should eq(0)
    buffer.messages.receive.should eq(Bytes[1])
    Fiber.yield
    credits.sum.should eq(first.size + 6)
    buffer.append(second[6..]).should eq(0)
    buffer.finish
    buffer.messages.receive.should eq(Bytes[2, 3, 4])
    buffer.messages.receive?.should be_nil
    credits.sum.should eq(first.size + second.size)
  ensure
    buffer.try(&.close)
  end

  it "accounts for compressed wire bytes rather than decoded payload size" do
    credits = [] of Int32
    buffer = GRPC::Transport::FlowControlledBuffer.new(->(bytes : Int32) { credits << bytes; nil })
    buffer.deframer.encoding = "gzip"
    payload = Bytes.new(128 * 1024, 42_u8)
    wire = GRPC::Codec.encode(payload, compress: true)
    partial = buffer.append(wire[0, 10])
    partial.should eq(10)
    buffer.append(wire[10..]).should eq(0)
    buffer.finish
    buffer.messages.receive.should eq(payload)
    buffer.messages.receive?.should be_nil
    (credits.sum + partial).should eq(wire.size)
  ensure
    buffer.try(&.close)
  end

  it "cancels a stalled consumer without holding a connection lock" do
    buffer = GRPC::Transport::FlowControlledBuffer.new
    buffer.append(GRPC::Codec.encode(Bytes[1]))
    Fiber.yield
    buffer.close
    buffer.messages.receive?.should be_nil
    buffer.append(GRPC::Codec.encode(Bytes[2])).should eq(0)
    buffer.close
  end
end

class FlowControlEchoService < GRPC::Service
  def initialize(@gate : Channel(Nil))
  end

  def service_full_name : String
    "test.FlowControl"
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    {request_body, GRPC::Status.ok}
  end

  def bidi_streaming?(method : String) : Bool
    method == "EchoStream" || method == "CountStream"
  end

  def dispatch_bidi_stream(method : String, requests : GRPC::RawRequestStream,
                           ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    @gate.receive
    if method == "CountStream"
      count = 0
      requests.each { |_message| count += 1 }
      writer.send_raw(count.to_s.to_slice)
    else
      requests.each { |message| writer.send_raw(message) }
    end
    GRPC::Status.ok
  end
end

private def with_flow_control_server(&)
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.port
  listener.close
  gate = Channel(Nil).new(1)
  server = GRPC::Server.new
  server.handle(FlowControlEchoService.new(gate))
  server.bind("127.0.0.1:#{port}")
  server.start
  channel = GRPC::Channel.new("127.0.0.1:#{port}")
  yield channel, gate
ensure
  gate.try(&.close)
  channel.try(&.close)
  server.try(&.stop)
end

describe "HTTP/2 receive flow control" do
  it "preserves a request burst before the handler starts consuming" do
    with_flow_control_server do |channel, gate|
      call = channel.open_bidi_stream_live("test.FlowControl", "CountStream", GRPC::ClientContext.new(deadline: Time.utc + 5.seconds))
      512.times { |i| call.send_raw(i.to_s.to_slice) }
      gate.send(nil)
      call.close_send
      received = [] of String
      call.each { |message| received << String.new(message) }
      fail call.status.to_s unless call.status.ok?
      received.should eq(["512"])
    end
  end

  it "delivers a burst exceeding both old message-count limits in both directions" do
    with_flow_control_server do |channel, gate|
      call = channel.open_bidi_stream_live("test.FlowControl", "EchoStream", GRPC::ClientContext.new(deadline: Time.utc + 5.seconds))
      512.times { |i| call.send_raw(i.to_s.to_slice) }
      gate.send(nil)
      call.close_send
      received = [] of String
      call.each { |message| received << String.new(message) }
      fail call.status.to_s unless call.status.ok?
      received.should eq((0...512).map(&.to_s))
      call.status.ok?.should be_true
    end
  end

  it "assembles messages larger than the window and lets other RPCs progress" do
    with_flow_control_server do |channel, gate|
      context = GRPC::ClientContext.new(deadline: Time.utc + 5.seconds)
      call = channel.open_bidi_stream_live("test.FlowControl", "EchoStream", context)
      payload = Bytes.new(256 * 1024, 42_u8)
      call.send_raw(payload)
      reply = channel.unary_call("test.FlowControl", "Echo", Bytes[7], context)
      fail reply.status.to_s unless reply.status.ok?
      reply.raw.should eq(Bytes[7])
      reply.status.ok?.should be_true
      gate.send(nil)
      call.close_send
      received = [] of Bytes
      call.each { |message| received << message }
      fail call.status.to_s unless call.status.ok?
      received.should eq([payload])
      call.status.ok?.should be_true
    end
  end
end
