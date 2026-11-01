require "../spec_helper"

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

  it "delivers 512-message bursts in both directions" do
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
