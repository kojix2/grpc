require "../spec_helper"
require "../support/frame_helpers"

describe GRPC::Codec do
  describe "framing and batches" do
    it "round-trips a message" do
      original = "Hello, gRPC!".to_slice
      framed = GRPC::Codec.encode(original)
      framed.size.should eq(original.size + GRPC::Codec::HEADER_SIZE)

      decoded, consumed = GRPC::Codec.decode(framed)
      decoded.should eq(original)
      consumed.should eq(framed.size)
    end

    it "decodes multiple messages" do
      msgs = ["foo", "bar", "baz"].map(&.to_slice)
      data = msgs.reduce(Bytes.empty) { |acc, msg| acc + GRPC::Codec.encode(msg) }
      result = GRPC::Codec.decode_all(data)
      result.size.should eq(3)
      result.map { |bytes| String.new(bytes) }.should eq(["foo", "bar", "baz"])
    end
  end

  describe "gzip" do
    it "round-trips a gzip-compressed message" do
      original = "Hello, compressed gRPC!".to_slice
      framed = GRPC::Codec.encode(original, compress: true)
      framed[0].should eq(1_u8) # compression flag set

      decoded, consumed = GRPC::Codec.decode(framed)
      decoded.should eq(original)
      consumed.should eq(framed.size)
    end

    it "transparently decodes mixed compressed/uncompressed frames" do
      plain = GRPC::Codec.encode("hello".to_slice)
      compressed = GRPC::Codec.encode("world".to_slice, compress: true)
      data = plain + compressed
      result = GRPC::Codec.decode_all(data)
      result.size.should eq(2)
      String.new(result[0]).should eq("hello")
      String.new(result[1]).should eq("world")
    end

    it "still accepts a valid gzip member containing an empty message" do
      wire = GRPC::Codec.encode(Bytes.empty, compress: true)
      GRPC::Codec.decode(wire, "gzip", validate_encoding: true)[0].should be_empty
    end

    it "requires grpc-encoding gzip when transport validation is enabled" do
      frame = GRPC::Codec.encode("compressed".to_slice, compress: true)
      expect_raises(GRPC::StatusError, /grpc-encoding: gzip/) do
        GRPC::Codec.decode(frame, nil, validate_encoding: true)
      end
      decoded, _ = GRPC::Codec.decode(frame, "gzip", validate_encoding: true)
      String.new(decoded).should eq("compressed")
    end

    it "rejects an unsupported declared encoding for an uncompressed frame" do
      frame = GRPC::Codec.encode("plain".to_slice)
      ex = expect_raises(GRPC::StatusError) do
        GRPC::Codec.decode(frame, "snappy", validate_encoding: true)
      end
      ex.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
    end

    [Bytes.empty, Bytes[1, 2, 3]].each do |payload|
      it "rejects invalid gzip payload #{payload} with INTERNAL" do
        wire = IO::Memory.new
        wire.write(GrpcFrameSpec.frame_header(1_u8, payload.size.to_u32))
        wire.write(payload)
        error = expect_raises(GRPC::StatusError) { GRPC::Codec.decode(wire.to_slice, "gzip", validate_encoding: true) }
        error.code.should eq(GRPC::StatusCode::INTERNAL)
      end
    end
  end

  describe "invalid frame headers and bodies" do
    it "raises on unknown compression flag" do
      # Flag 0x02 is not a recognised compression algorithm
      bad_frame = Bytes[0x02, 0x00, 0x00, 0x00, 0x00]
      expect_raises(GRPC::StatusError) do
        GRPC::Codec.decode(bad_frame)
      end
    end

    it "raises INTERNAL for incomplete frame header" do
      ex = expect_raises(GRPC::StatusError) do
        GRPC::Codec.decode(Bytes[0x00, 0x00, 0x00, 0x00])
      end

      ex.status.code.should eq(GRPC::StatusCode::INTERNAL)
      ex.status.message.should eq("incomplete gRPC frame header")
    end

    it "raises INTERNAL for incomplete frame body" do
      # Header says body length is 3, but only 2 bytes follow.
      truncated = Bytes[0x00, 0x00, 0x00, 0x00, 0x03, 0x41, 0x42]
      ex = expect_raises(GRPC::StatusError) do
        GRPC::Codec.decode(truncated)
      end

      ex.status.code.should eq(GRPC::StatusCode::INTERNAL)
      ex.status.message.should eq("incomplete gRPC frame body")
    end

    [0x7ffffffb_u32, 0x80000000_u32, 0xffffffff_u32].each do |length|
      it "rejects unrepresentable length #{length} before reading the payload" do
        header = GrpcFrameSpec.frame_header(0_u8, length)
        error = expect_raises(GRPC::StatusError) { GRPC::Codec.decode(header) }
        error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      end
    end
  end
end
