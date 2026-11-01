require "../spec_helper"
require "../support/frame_helpers"

describe "transport receive limits" do
  it "rejects oversized streamed headers before buffering their payloads" do
    stream = GRPC::Transport::PendingStream.new(GRPC::ReceiveLimits.new(max_message_size: 4))
    stream.receive_data(GrpcFrameSpec.frame_header(0_u8, 5_u32))
    stream.messages.receive?.should be_nil
    stream.grpc_status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
  end

  it "bounds a stalled consumer's decoded backlog across separate appends" do
    limits = GRPC::ReceiveLimits.new(max_message_size: 4, max_buffered_bytes: 7)
    buffer = GRPC::Transport::FlowControlledBuffer.new(limits: limits)
    frame = GRPC::Codec.encode(Bytes[1, 2, 3, 4])
    buffer.append(frame)
    Fiber.yield
    error = expect_raises(GRPC::StatusError) { buffer.append(frame) }
    error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
  ensure
    buffer.try &.close
  end

  it "checks each coalesced compressed frame against the decoded backlog budget" do
    limits = GRPC::ReceiveLimits.new(max_message_size: 4, max_buffered_bytes: 7)
    buffer = GRPC::Transport::FlowControlledBuffer.new(limits: limits)
    buffer.deframer.encoding = "gzip"
    frame = GRPC::Codec.encode(Bytes[1, 2, 3, 4], compress: true)
    error = expect_raises(GRPC::StatusError) { buffer.append(frame + frame) }
    error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
  ensure
    buffer.try &.close
  end

  it "releases the decoded budget after consumption for a long-lived stream" do
    limits = GRPC::ReceiveLimits.new(max_message_size: 4, max_buffered_bytes: 4)
    buffer = GRPC::Transport::FlowControlledBuffer.new(limits: limits)
    frame = GRPC::Codec.encode(Bytes[1, 2, 3, 4])
    100.times do
      buffer.append(frame)
      buffer.messages.receive.should eq(Bytes[1, 2, 3, 4])
      Fiber.yield
    end
    buffer.finish
    buffer.messages.receive?.should be_nil
  ensure
    buffer.try &.close
  end

  it "completes and resets an oversized unary response without accepting later DATA" do
    call = GRPC::Transport::PendingCall.new(GRPC::ReceiveLimits.new(max_wire_size: 4))
    cancelled = Channel(Nil).new(1)
    cancellations = 0
    call.cancel_proc = -> { cancellations += 1; cancelled.send(nil); nil }
    call.receive_data(GrpcFrameSpec.frame_header(0_u8, 5_u32))
    call.wait
    call.grpc_status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
    call.receive_data(Bytes.new(100)).should eq(0)
    call.response_bytes.size.should eq(5)
    select
    when cancelled.receive
    when timeout(1.second)
      fail "oversized unary response was not reset"
    end
    call.cancel
    cancellations.should eq(1)
  end
end
