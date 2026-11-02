require "../spec_helper"

describe GRPC::Transport::TrailerCodec do
  {"日本語 é α % + space" => "%E6%97%A5%E6%9C%AC%E8%AA%9E %C3%A9 %CE%B1 %25 + space",
   "a\n\0z"            => "a%0A%00z"}.each do |message, encoded|
    it "encodes #{message.inspect} as ASCII and recovers the original bytes" do
      GRPC::Transport::TrailerCodec.percent_encode(message).should eq(encoded)
      GRPC::Transport::TrailerCodec.percent_decode(encoded).should eq(message)
    end
  end

  it "preserves raw UTF-8 and malformed percent escapes while decoding" do
    GRPC::Transport::TrailerCodec.percent_decode("é %zz %2 % +").should eq("é %zz %2 % +")
  end

  it "preserves malformed escapes containing non-UTF-8 bytes" do
    wire = String.new(Bytes[0x25, 0xff, 0x20])
    GRPC::Transport::TrailerCodec.percent_decode(wire).to_slice.should eq(wire.to_slice)
  end
end
