require "../spec_helper"
require "../support/messages"

describe GRPC::Marshaller do
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
