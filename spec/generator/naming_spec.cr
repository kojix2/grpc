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

describe CrystalGrpcCodeGenerator do
  it "allocates unary response helpers around all public RPC names" do
    methods = {"Foo", "FooResponse", "FooResponse_2"}.map do |name|
      GrpcGeneratorSpec::TestProtoEncode.method_proto(name, ".audit.Request", ".audit.Reply")
    end.to_a
    service = GrpcGeneratorSpec::TestProtoEncode.service_proto("Echo", methods)
    file = GrpcGeneratorSpec::TestProtoEncode.file_proto("collision.proto", "audit", [service])
    content = GrpcGeneratorSpec.run_generator(GrpcGeneratorSpec::TestProtoEncode.request(["collision.proto"], [file]), "collision.grpc.cr")
    content.should contain("foo_response_3(request, ctx).ok!")
    content.should contain("def foo_response_3(request")
    content.should contain("def foo_response(request")
    content.should contain("def foo_response_2(request")
  end

  [{"FooBar", "Foo_Bar"}, {"Dispatch", "Ping"}, {"MarshallerFor", "Ping"}].each do |names|
    it "diagnoses RPC method name collisions for #{names.join(", ")}" do
      methods = names.map { |name| GrpcGeneratorSpec::TestProtoEncode.method_proto(name, ".audit.Request", ".audit.Reply") }.to_a
      service = GrpcGeneratorSpec::TestProtoEncode.service_proto("Echo", methods)
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("collision.proto", "audit", [service])
      request = GrpcGeneratorSpec.parse_request(GrpcGeneratorSpec::TestProtoEncode.request(["collision.proto"], [file]))
      expect_raises(ArgumentError, /collides with generated method/) { CrystalGrpcCodeGenerator.new.run(request) }
    end
  end
end
