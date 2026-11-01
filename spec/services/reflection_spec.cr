require "../spec_helper"
require "../support/reflection"

describe GRPC::Reflection::Service do
  it "lists registered services" do
    service = GRPC::Reflection::Service.new
    service.register_service("demo.Greeter")
    sent = [] of Bytes
    writer = GRPC::RawResponseStream.new(->(framed : Bytes) {
      body, _ = GRPC::Codec.decode(framed)
      sent << body
      nil
    })
    requests = ::Channel(Bytes?).new(1)
    requests.send(ReflectionSpecWire.encode_request(7, ""))
    requests.close

    status = service.dispatch_bidi_stream(
      "ServerReflectionInfo",
      GRPC::RawRequestStream.new(requests),
      GRPC::ServerContext.new("peer", GRPC::Metadata.new),
      writer,
    )

    status.ok?.should be_true
    ReflectionSpecWire.decode_list_services_response(sent[0]).should eq([
      "demo.Greeter",
      GRPC::Reflection::Service::SERVICE_FULL_NAME,
    ])
  end

  it "returns the matching file descriptor for symbol lookups" do
    descriptor = ReflectionSpecWire.build_demo_file_descriptor_proto
    service = GRPC::Reflection::Service.new
    service.register_service("demo.Greeter")
    service.add_file_descriptor(descriptor)

    sent = [] of Bytes
    writer = GRPC::RawResponseStream.new(->(framed : Bytes) {
      body, _ = GRPC::Codec.decode(framed)
      sent << body
      nil
    })
    requests = ::Channel(Bytes?).new(1)
    requests.send(ReflectionSpecWire.encode_request(4, "demo.HelloRequest"))
    requests.close

    status = service.dispatch_bidi_stream(
      "ServerReflectionInfo",
      GRPC::RawRequestStream.new(requests),
      GRPC::ServerContext.new("peer", GRPC::Metadata.new),
      writer,
    )

    status.ok?.should be_true
    ReflectionSpecWire.decode_file_descriptor_response(sent[0]).should eq([descriptor])
  end

  it "replaces symbol mappings when a descriptor file is re-registered" do
    original_descriptor = ReflectionSpecWire.build_demo_file_descriptor_proto
    replacement_descriptor = ReflectionSpecWire.build_demo_file_descriptor_proto(
      request_name: "RenamedRequest",
      reply_name: "RenamedReply",
    )
    service = GRPC::Reflection::Service.new
    service.register_service("demo.Greeter")
    service.add_file_descriptor(original_descriptor)
    service.add_file_descriptor(replacement_descriptor)

    sent = [] of Bytes
    writer = GRPC::RawResponseStream.new(->(framed : Bytes) {
      body, _ = GRPC::Codec.decode(framed)
      sent << body
      nil
    })
    requests = ::Channel(Bytes?).new(2)
    requests.send(ReflectionSpecWire.encode_request(4, "demo.HelloRequest"))
    requests.send(ReflectionSpecWire.encode_request(4, "demo.RenamedRequest"))
    requests.close

    status = service.dispatch_bidi_stream(
      "ServerReflectionInfo",
      GRPC::RawRequestStream.new(requests),
      GRPC::ServerContext.new("peer", GRPC::Metadata.new),
      writer,
    )

    status.ok?.should be_true
    ReflectionSpecWire.decode_error_response(sent[0]).should eq({5, "symbol not found: demo.HelloRequest"})
    ReflectionSpecWire.decode_file_descriptor_response(sent[1]).should eq([replacement_descriptor])
  end

  it "server registers existing and later services with reflection" do
    server = GRPC::Server.new
    server.handle(ReflectionRegistryProbeService.new)

    reflection = server.enable_reflection

    reflection.register_service("extra.Debug")

    sent = [] of Bytes
    writer = GRPC::RawResponseStream.new(->(framed : Bytes) {
      body, _ = GRPC::Codec.decode(framed)
      sent << body
      nil
    })
    requests = ::Channel(Bytes?).new(1)
    requests.send(ReflectionSpecWire.encode_request(7, ""))
    requests.close

    status = reflection.dispatch_bidi_stream(
      "ServerReflectionInfo",
      GRPC::RawRequestStream.new(requests),
      GRPC::ServerContext.new("peer", GRPC::Metadata.new),
      writer,
    )

    status.ok?.should be_true
    ReflectionSpecWire.decode_list_services_response(sent[0]).should contain("demo.Greeter")
    ReflectionSpecWire.decode_list_services_response(sent[0]).should contain("extra.Debug")
  end
end
