require "../support/generator_helpers"

describe CrystalGrpcCodeGenerator do
  describe "output options" do
    it "skips files with no services" do
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("empty.proto", "empty", [] of Bytes)
      req_bytes = GrpcGeneratorSpec::TestProtoEncode.request(["empty.proto"], [file])

      request = GrpcGeneratorSpec.parse_request(req_bytes)
      generator = CrystalGrpcCodeGenerator.new
      response_bytes = generator.run(request)

      content = GrpcGeneratorSpec.extract_file_content(response_bytes, "empty.grpc.cr")
      content.should be_nil
    end

    it "supports paths=import by emitting basename output" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto("Ping", ".pkg.Req", ".pkg.Res")
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("EchoService", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("dir/sub/echo.proto", "pkg", [svc])

      request = GrpcGeneratorSpec.parse_request(
        GrpcGeneratorSpec::TestProtoEncode.request(["dir/sub/echo.proto"], [file], "paths=import")
      )
      generator = CrystalGrpcCodeGenerator.new
      response_bytes = generator.run(request)

      GrpcGeneratorSpec.extract_file_content(response_bytes, "echo.grpc.cr").should_not be_nil
      GrpcGeneratorSpec.extract_file_content(response_bytes, "dir/sub/echo.grpc.cr").should be_nil
    end

    it "omits the client when stub=false" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto("Ping", ".pkg.Req", ".pkg.Res")
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("EchoService", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("echo.proto", "pkg", [svc])

      only_server = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["echo.proto"], [file], "stub=false,server=true"),
        "echo.grpc.cr"
      )
      only_server.should contain("abstract class Service < GRPC::Service")
      only_server.should_not contain("class Client")
    end

    it "omits the service when server=false" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto("Ping", ".pkg.Req", ".pkg.Res")
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("EchoService", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("echo.proto", "pkg", [svc])

      only_stub = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["echo.proto"], [file], "stub=true,server=false"),
        "echo.grpc.cr"
      )
      only_stub.should contain("class Client")
      only_stub.should_not contain("abstract class Service < GRPC::Service")
    end

    it "supports descriptor=false" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto("Ping", ".pkg.Req", ".pkg.Res")
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("EchoService", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("echo.proto", "pkg", [svc])

      content = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["echo.proto"], [file], "descriptor=false"),
        "echo.grpc.cr"
      )
      content.should_not contain("FILE_DESCRIPTOR_PROTO_BYTES")
    end
  end
end
