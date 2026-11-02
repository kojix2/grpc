require "../spec_helper"

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
    512.times { |i| String.new(buffer.messages.receive.should_not be_nil).should eq(i.to_s) }
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
