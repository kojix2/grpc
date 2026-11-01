require "../spec_helper"
require "../support/frame_helpers"

describe GRPC::Transport::UnaryMessageBuffer do
  it "accepts one frame at the exact limit across fragmented DATA" do
    buffer = GRPC::Transport::UnaryMessageBuffer.new(GRPC::ReceiveLimits.new(max_wire_size: 4, max_message_size: 4))
    frame = GRPC::Codec.encode(Bytes[1, 2, 3, 4])
    frame.each { |byte| buffer.append(Bytes[byte]) }
    buffer.io.to_slice.should eq(frame)
  end

  it "rejects excessive accumulation before copying a DATA chunk" do
    buffer = GRPC::Transport::UnaryMessageBuffer.new(GRPC::ReceiveLimits.new(max_wire_size: 4))
    error = expect_raises(GRPC::StatusError) { buffer.append(Bytes.new(100)) }
    error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
    buffer.io.size.should eq(0)
  end

  it "validates a split oversized header without waiting for END_STREAM" do
    buffer = GRPC::Transport::UnaryMessageBuffer.new(GRPC::ReceiveLimits.new(max_wire_size: 32))
    header = GrpcFrameSpec.frame_header(0_u8, 33_u32)
    buffer.append(header[0, 3])
    error = expect_raises(GRPC::StatusError) { buffer.append(header[3..]) }
    error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
    buffer.io.size.should eq(5)
  end

  it "rejects a second unary frame instead of accumulating messages" do
    buffer = GRPC::Transport::UnaryMessageBuffer.new
    frame = GRPC::Codec.encode(Bytes[1])
    buffer.append(frame)
    error = expect_raises(GRPC::StatusError) { buffer.append(frame) }
    error.code.should eq(GRPC::StatusCode::INTERNAL)
  end
end
