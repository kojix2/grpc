require "../support/generator_helpers"

describe CrystalGrpcCodeGenerator do
  describe "type resolution" do
    it "handles cross-package type references" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "Ping",
        ".google.protobuf.Empty",
        ".mypkg.Reply"
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Svc", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("svc.proto", "mypkg", [svc])

      content = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["svc.proto"], [file]),
        "svc.grpc.cr"
      )
      # .google.protobuf.Empty → Google::Protobuf::Empty (different package)
      content.should contain("Google::Protobuf::Empty")
      # .mypkg.Reply in the mypkg package → just Reply
      content.should contain(": Reply")
    end

    it "uses canonical resolution when type_map is not provided" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "Query",
        ".acme_ml.v1.RequestEnvelope.Payload",
        ".third_party.shared.v2.Result.Container"
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Gateway", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("gateway.proto", "acme_ml.v1", [svc])

      content = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["gateway.proto"], [file]),
        "gateway.grpc.cr"
      )
      content.should contain("RequestEnvelope::Payload")
      content.should contain("ThirdParty::Shared::V2::Result::Container")
    end

    it "prefers type_map mappings when provided" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "Ping",
        ".google.protobuf.Empty",
        ".mypkg.Reply"
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Svc", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("svc.proto", "mypkg", [svc])
      req = GrpcGeneratorSpec::TestProtoEncode.request(
        ["svc.proto"],
        [file],
        "type_map=.google.protobuf.Empty=My::Custom::Empty;.mypkg.Reply=Reply"
      )

      content = GrpcGeneratorSpec.run_generator(req, "svc.grpc.cr")
      content.should contain("My::Custom::Empty")
      content.should_not contain("Google::Protobuf::Empty")
    end

    it "parses type_map parameters with surrounding whitespace" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "Ping",
        ".google.protobuf.Empty",
        ".mypkg.Reply"
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Svc", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("svc.proto", "mypkg", [svc])
      req = GrpcGeneratorSpec::TestProtoEncode.request(
        ["svc.proto"],
        [file],
        " type_map = .google.protobuf.Empty = My::Custom::Empty ; .mypkg.Reply = Reply "
      )

      content = GrpcGeneratorSpec.run_generator(req, "svc.grpc.cr")
      content.should contain("My::Custom::Empty")
      content.should_not contain("Google::Protobuf::Empty")
    end

    it "resolves underscore+nested+import-style types via type_map" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "Query",
        ".acme_ml.v1.RequestEnvelope.Payload",
        ".third_party.shared.v2.Result.Container"
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Gateway", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("gateway.proto", "acme_ml.v1", [svc])
      req = GrpcGeneratorSpec::TestProtoEncode.request(
        ["gateway.proto"],
        [file],
        "type_map=.acme_ml.v1.RequestEnvelope.Payload=AcmeML::V1::RequestEnvelope::Payload;.third_party.shared.v2.Result.Container=Shared::V2::Result::Container"
      )

      content = GrpcGeneratorSpec.run_generator(req, "gateway.grpc.cr")
      content.should contain("AcmeML::V1::RequestEnvelope::Payload")
      content.should contain("Shared::V2::Result::Container")
      content.should contain("module AcmeMl::V1")
    end

    it "uses strict type_map mode when mapping is incomplete" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "Query",
        ".acme_ml.v1.RequestEnvelope.Payload",
        ".third_party.shared.v2.Result.Container"
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Gateway", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("gateway.proto", "acme_ml.v1", [svc])
      req = GrpcGeneratorSpec::TestProtoEncode.request(
        ["gateway.proto"],
        [file],
        "type_map=.acme_ml.v1.RequestEnvelope.Payload=AcmeML::V1::RequestEnvelope::Payload"
      )

      request = GrpcGeneratorSpec.parse_request(req)
      generator = CrystalGrpcCodeGenerator.new
      expect_raises(ArgumentError, /Missing type_map entry/) do
        generator.run(request)
      end
    end
  end
end
