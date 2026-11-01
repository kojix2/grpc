require "../spec_helper"
require "../support/frame_helpers"

describe GRPC::Codec do
  describe "receive limits" do
    {false, true}.each do |compressed|
      it "accepts a decoded message exactly at the limit with compression=#{compressed}" do
        limits = GRPC::ReceiveLimits.new(max_message_size: 32)
        payload = Bytes.new(32, 42_u8)
        frame = GRPC::Codec.encode(payload, compress: compressed)
        GRPC::Codec.decode(frame, limits: limits)[0].should eq(payload)
      end
    end

    it "rejects an oversized wire length before its payload arrives" do
      header = GrpcFrameSpec.frame_header(1_u8, 33_u32)
      limits = GRPC::ReceiveLimits.new(max_wire_size: 32)
      error = expect_raises(GRPC::StatusError) { GRPC::Codec.decode(header, limits: limits) }
      error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
    end

    it "rejects an oversized uncompressed message from its header" do
      header = GrpcFrameSpec.frame_header(0_u8, 33_u32)
      limits = GRPC::ReceiveLimits.new(max_message_size: 32)
      error = expect_raises(GRPC::StatusError) { GRPC::Codec.decode(header, limits: limits) }
      error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
    end

    it "bounds gzip output even when the wire message fits" do
      limits = GRPC::ReceiveLimits.new(max_wire_size: 128, max_message_size: 64)
      frame = GRPC::Codec.encode(Bytes.new(8192, 42_u8), compress: true)
      frame.size.should be < 128
      error = expect_raises(GRPC::StatusError) { GRPC::Codec.decode(frame, limits: limits) }
      error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      error.message.should contain("decompressed")
    end

    it "still validates gzip checksums within the decoded size limit" do
      frame = GRPC::Codec.encode(Bytes[1, 2, 3], compress: true)
      frame[-1] ^= 0xff_u8
      error = expect_raises(GRPC::StatusError) { GRPC::Codec.decode(frame, limits: GRPC::ReceiveLimits.new(max_message_size: 32)) }
      error.code.should eq(GRPC::StatusCode::INTERNAL)
    end

    it "bounds the aggregate decoded size of a batch" do
      frame = GRPC::Codec.encode(Bytes[1, 2, 3, 4], compress: true)
      limits = GRPC::ReceiveLimits.new(max_message_size: 4, max_buffered_bytes: 7)
      error = expect_raises(GRPC::StatusError) { GRPC::Codec.decode_all(frame + frame, limits) }
      error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
    end
  end
end
