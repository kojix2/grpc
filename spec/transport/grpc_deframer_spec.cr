require "../spec_helper"
require "../support/frame_helpers"

describe GRPC::Transport::GrpcDeframer do
  describe "fragmented delivery" do
    it "drains only complete frames and preserves remainder" do
      buffer = GRPC::Transport::GrpcDeframer.new
      msg1 = GRPC::Codec.encode("hello".to_slice)
      msg2 = GRPC::Codec.encode("world".to_slice)

      partial = msg2[0, 3]
      rest = msg2[3, msg2.size - 3]

      buffer.append(msg1 + partial)
      drained = buffer.drain_messages
      drained.size.should eq(1)
      String.new(drained[0]).should eq("hello")
      buffer.remainder_size.should eq(3)

      buffer.append(rest)
      drained2 = buffer.drain_messages
      drained2.size.should eq(1)
      String.new(drained2[0]).should eq("world")
      buffer.remainder_size.should eq(0)
    end

    it "parses a frame header split across multiple chunks" do
      buffer = GRPC::Transport::GrpcDeframer.new
      frame = GRPC::Codec.encode("header-boundary".to_slice)

      buffer.append(frame[0, 2])
      buffer.drain_messages.should be_empty
      buffer.append(frame[2, 2])
      buffer.drain_messages.should be_empty
      buffer.append(frame[4, frame.size - 4])

      drained = buffer.drain_messages
      drained.size.should eq(1)
      String.new(drained[0]).should eq("header-boundary")
      buffer.remainder_size.should eq(0)
    end

    it "handles one-byte fragmented delivery without losing message boundaries" do
      buffer = GRPC::Transport::GrpcDeframer.new
      payload = "x" * 16_384
      frame = GRPC::Codec.encode(payload.to_slice)
      drained = [] of Bytes

      frame.each do |byte|
        chunk = Bytes.new(1)
        chunk[0] = byte
        buffer.append(chunk)
        drained.concat(buffer.drain_messages)
      end

      drained.size.should eq(1)
      String.new(drained[0]).should eq(payload)
      buffer.remainder_size.should eq(0)
    end

    it "decodes multiple frames split across uneven chunk sizes" do
      buffer = GRPC::Transport::GrpcDeframer.new
      msg1 = GRPC::Codec.encode("alpha".to_slice)
      msg2 = GRPC::Codec.encode("beta".to_slice)
      msg3 = GRPC::Codec.encode("gamma".to_slice)
      wire = msg1 + msg2 + msg3

      drained = [] of Bytes
      chunk_sizes = [2, 7, 1, 11, 3, 5] of Int32
      offset = 0
      index = 0

      while offset < wire.size
        requested = chunk_sizes[index % chunk_sizes.size]
        size = Math.min(requested, wire.size - offset)
        buffer.append(wire[offset, size])
        drained.concat(buffer.drain_messages)
        offset += size
        index += 1
      end

      drained.map { |bytes| String.new(bytes) }.should eq(["alpha", "beta", "gamma"])
      buffer.remainder_size.should eq(0)
    end

    it "decodes compressed frames split across uneven chunks" do
      buffer = GRPC::Transport::GrpcDeframer.new
      frame = GRPC::Codec.encode("compressed payload".to_slice, compress: true)

      buffer.append(frame[0, 3])
      buffer.drain_messages.should be_empty
      buffer.append(frame[3, 4])
      buffer.drain_messages.should be_empty
      buffer.append(frame[7, frame.size - 7])

      drained = buffer.drain_messages
      drained.size.should eq(1)
      String.new(drained[0]).should eq("compressed payload")
      buffer.remainder_size.should eq(0)
    end
  end

  describe "frame header validation" do
    it "keeps a representable incomplete frame pending rather than inventing a message" do
      limits = GRPC::ReceiveLimits.new(max_wire_size: 0x7ffffffa, max_message_size: 0x7ffffffa)
      deframer = GRPC::Transport::GrpcDeframer.new(limits: limits)
      deframer.append(GrpcFrameSpec.frame_header(0_u8, 0x7ffffffa_u32))
      deframer.drain_messages.should be_empty
      deframer.remainder_size.should eq(5)
    end

    it "rejects an unsupported compression flag without waiting for the payload" do
      header = GrpcFrameSpec.frame_header(2_u8, 1000_u32)
      deframer = GRPC::Transport::GrpcDeframer.new
      deframer.append(header)
      error = expect_raises(GRPC::StatusError) { deframer.drain_messages }
      error.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
    end

    [0x7ffffffb_u32, 0x80000000_u32, 0xffffffff_u32].each do |length|
      it "rejects unrepresentable length #{length} after a fragmented header" do
        header = GrpcFrameSpec.frame_header(0_u8, length)
        deframer = GRPC::Transport::GrpcDeframer.new
        header.each do |byte|
          deframer.append(Bytes[byte])
          next if deframer.remainder_size < GRPC::Codec::HEADER_SIZE
          error = expect_raises(GRPC::StatusError) { deframer.drain_messages }
          error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
        end
      end
    end
  end
end
