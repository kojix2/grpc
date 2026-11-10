require "../spec_helper"
require "../support/messages"

private class OptionsMessage
  getter value : Int32

  def initialize(@value : Int32)
  end

  def encode : Bytes
    Bytes[@value.to_u8]
  end

  def encode(*, options : Int32) : Bytes
    Bytes[(@value + options).to_u8]
  end

  def self.decode(bytes : Bytes) : self
    new(bytes[0].to_i32)
  end

  def self.decode(bytes : Bytes, *, options : Int32) : self
    new(bytes[0].to_i32 - options)
  end
end

describe GRPC::Marshaller do
  it "passes serialization options to a configured proto marshaller" do
    marshaller = GRPC::ProtoMarshaller(OptionsMessage).new(encode_options: 2, decode_options: 2)
    bytes = marshaller.encode(OptionsMessage.new(40))
    bytes.should eq(Bytes[42])
    marshaller.decode(bytes).value.should eq(40)
    GRPC::ProtoMarshaller(OptionsMessage).new.encode(OptionsMessage.new(40)).should eq(Bytes[40])
  end

  it "decodes request stream messages via a custom marshaller" do
    ch = ::Channel(Bytes?).new(2)
    ch.send("A".to_slice)
    ch.send("B".to_slice)
    ch.close

    stream = GRPC::RequestStream(DummyMessage).new(ch, TestDummyMarshaller.new)
    values = [] of DummyMessage
    stream.each { |v| values << v }

    values.map(&.value).should eq(["in:A", "in:B"])
  end

  it "encodes response stream messages via a custom marshaller" do
    sent = [] of Bytes
    raw = GRPC::RawResponseStream.new(->(bytes : Bytes) { sent << bytes; nil })
    stream = GRPC::ResponseStream(DummyMessage).new(raw, TestDummyMarshaller.new)

    stream.send(DummyMessage.new("hello"))

    body, _consumed = GRPC::Codec.decode(sent[0])
    String.new(body).should eq("out:hello")
  end

  it "decodes envelopes via a custom marshaller" do
    info = GRPC::CallInfo.new("/svc/m", GRPC::RPCKind::Unary)
    req = GRPC::RequestEnvelope.new(info, "xyz".to_slice)
    res = GRPC::ResponseEnvelope.new(info, "xyz".to_slice, GRPC::Status.ok)

    req.decode(DummyMessage, TestDummyMarshaller.new).value.should eq("in:xyz")
    res.decode(DummyMessage, TestDummyMarshaller.new).value.should eq("in:xyz")
  end
end
