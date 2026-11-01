require "../spec_helper"

describe GRPC::ReceiveLimits do
  it "has finite defaults for wire, decoded and queued data" do
    limits = GRPC::ReceiveLimits.new
    limits.max_wire_size.should eq(64 * 1024 * 1024)
    limits.max_message_size.should eq(64 * 1024 * 1024)
    limits.max_buffered_bytes.should eq(64 * 1024 * 1024)
  end

  {0, -1}.each do |value|
    {"wire", "message", "buffer"}.each do |field|
      it "rejects #{field} limit #{value}" do
        expect_raises(ArgumentError) do
          case field
          when "wire"    then GRPC::ReceiveLimits.new(max_wire_size: value)
          when "message" then GRPC::ReceiveLimits.new(max_message_size: value)
          when "buffer"  then GRPC::ReceiveLimits.new(max_buffered_bytes: value)
          end
        end
      end
    end
  end

  it "leaves room for frame-header arithmetic" do
    expect_raises(ArgumentError) { GRPC::ReceiveLimits.new(max_wire_size: Int32::MAX) }
  end

  it "leaves room for the decompression overflow sentinel" do
    expect_raises(ArgumentError) { GRPC::ReceiveLimits.new(max_message_size: Int32::MAX) }
  end
end
