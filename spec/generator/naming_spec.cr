require "../support/generator_helpers"

describe CrystalGrpcCodeGenerator do
  describe "packages and method names" do
    it "wraps generated code in a module for a non-empty package" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "SayHello",
        ".helloworld.HelloRequest",
        ".helloworld.HelloReply"
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Greeter", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("helloworld.proto", "helloworld", [svc])

      content = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["helloworld.proto"], [file]),
        "helloworld.grpc.cr"
      )
      content.should contain("module Helloworld")
      content.should contain("end\n")
    end

    it "emits no module wrapper for files without a package" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto("Ping", ".Echo", ".Echo")
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("EchoService", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("echo.proto", "", [svc])

      content = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["echo.proto"], [file]),
        "echo.grpc.cr"
      )
      content.should contain("module EchoService")
      content.should contain("abstract class Service < GRPC::Service")
    end

    it "snake_cases RPC method names" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto("GetUserById", ".myapp.Foo", ".myapp.Bar")
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("UserService", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("user.proto", "myapp", [svc])

      content = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["user.proto"], [file]),
        "user.grpc.cr"
      )
      content.should contain("def get_user_by_id(")
    end

    it "escapes Crystal keyword method names" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto("Class", ".myapp.Foo", ".myapp.Bar")
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("UserService", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("user.proto", "myapp", [svc])

      content = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["user.proto"], [file]),
        "user.grpc.cr"
      )
      content.should contain("def class_(")
      content.should_not contain("def class(")
    end
  end
end
