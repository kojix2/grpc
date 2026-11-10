require "../support/generator_helpers"

describe CrystalGrpcCodeGenerator do
  describe "RPC shapes" do
    it "generates a unary service stub" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "SayHello",
        ".helloworld.HelloRequest",
        ".helloworld.HelloReply"
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Greeter", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("helloworld.proto", "helloworld", [svc])
      req_bytes = GrpcGeneratorSpec::TestProtoEncode.request(["helloworld.proto"], [file])

      request = GrpcGeneratorSpec.parse_request(req_bytes)
      generator = CrystalGrpcCodeGenerator.new
      response_bytes = generator.run(request)

      # Parse the response to extract the generated file content
      c = GrpcGeneratorSpec.extract_file_content(response_bytes, "helloworld.grpc.cr") ||
          fail("Expected helloworld.grpc.cr to be generated")

      c.should contain("module Greeter")
      c.should contain("FULL_NAME = \"helloworld.Greeter\"")
      c.should contain("FILE_DESCRIPTOR_PROTO_BYTES = Bytes[")
      c.should contain("abstract class Service < GRPC::Service")
      c.should contain(%("helloworld.Greeter"))
      c.should contain("abstract def say_hello(request : ::Helloworld::HelloRequest, ctx : GRPC::ServerContext) : ::Helloworld::HelloReply")
      c.should contain("class Client")
      c.should contain("def say_hello(request : ::Helloworld::HelloRequest, ctx : GRPC::ClientContext")
      c.should contain("@channel.unary_call")
      c.should contain("protected def marshaller_for(type : T.class) : GRPC::Marshaller(T) forall T")
      c.should contain("res_marshaller = marshaller_for(::Helloworld::HelloReply, ctx)")
      c.should contain("res_marshaller.decode(response.raw)")
      c.should contain("response.status.ok? ? res_marshaller.decode(response.raw) : nil")
    end

    it "generates a server-streaming stub" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "Range",
        ".numbers.Number",
        ".numbers.Number",
        server_streaming: true
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Numbers", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("numbers.proto", "numbers", [svc])
      req_bytes = GrpcGeneratorSpec::TestProtoEncode.request(["numbers.proto"], [file])

      content = GrpcGeneratorSpec.run_generator(req_bytes, "numbers.grpc.cr")
      content.should contain("def server_streaming?(method : String) : Bool")
      content.should contain(%("Range"))
      content.should contain("dispatch_server_stream")
      content.should contain("GRPC::ServerStream(::Numbers::Number)")
      content.should contain("open_server_stream")
      content.should contain("req_marshaller = marshaller_for(::Numbers::Number, ctx)")
      content.should contain("res_marshaller = marshaller_for(::Numbers::Number, ctx)")
      content.should contain(".new(raw, res_marshaller)")
      content.should_not contain("stream.push")
    end

    it "generates a client-streaming stub" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "Sum",
        ".numbers.Number",
        ".numbers.Number",
        client_streaming: true
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Numbers", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("numbers.proto", "numbers", [svc])

      content = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["numbers.proto"], [file]),
        "numbers.grpc.cr"
      )
      content.should contain("def client_streaming?(method : String) : Bool")
      content.should contain("dispatch_client_stream")
      content.should contain("open_client_stream_live")
      content.should contain("GRPC::ClientStream(::Numbers::Number, ::Numbers::Number)")
      content.should contain("GRPC::RequestStream(::Numbers::Number)")
      content.should contain("req_marshaller = marshaller_for(::Numbers::Number, ctx)")
      content.should contain("res_marshaller = marshaller_for(::Numbers::Number, ctx)")
      content.should contain("raw.send_raw(req_marshaller.encode(msg))")
      content.should contain("result_chan.send(res_marshaller.decode(body))")
      content.should_not contain("result_chan.send(res_marshaller.decode(body)) rescue nil")
    end

    it "generates a bidirectional-streaming stub" do
      method = GrpcGeneratorSpec::TestProtoEncode.method_proto(
        "Transform",
        ".numbers.Number",
        ".numbers.Number",
        client_streaming: true,
        server_streaming: true
      )
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Numbers", [method])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("numbers.proto", "numbers", [svc])

      content = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["numbers.proto"], [file]),
        "numbers.grpc.cr"
      )
      content.should contain("def bidi_streaming?(method : String) : Bool")
      content.should contain("dispatch_bidi_stream")
      content.should contain("open_bidi_stream")
      content.should contain("req_marshaller = marshaller_for(::Numbers::Number, ctx)")
      content.should contain("res_marshaller = marshaller_for(::Numbers::Number, ctx)")
      content.should contain(".new(raw, req_marshaller, res_marshaller)")
      content.should_not contain("recv_chan")
    end

    it "generates service stubs for all 4 RPC types in one service" do
      unary = GrpcGeneratorSpec::TestProtoEncode.method_proto("Unary", ".echo.Req", ".echo.Res")
      ss = GrpcGeneratorSpec::TestProtoEncode.method_proto("ServerStream", ".echo.Req", ".echo.Res", server_streaming: true)
      cs = GrpcGeneratorSpec::TestProtoEncode.method_proto("ClientStream", ".echo.Req", ".echo.Res", client_streaming: true)
      bidi = GrpcGeneratorSpec::TestProtoEncode.method_proto("Bidi", ".echo.Req", ".echo.Res", client_streaming: true, server_streaming: true)
      svc = GrpcGeneratorSpec::TestProtoEncode.service_proto("Echo", [unary, ss, cs, bidi])
      file = GrpcGeneratorSpec::TestProtoEncode.file_proto("echo.proto", "echo", [svc])

      content = GrpcGeneratorSpec.run_generator(
        GrpcGeneratorSpec::TestProtoEncode.request(["echo.proto"], [file]),
        "echo.grpc.cr"
      )
      content.should contain("module Echo")
      # All abstract methods present
      content.should contain("abstract def unary(")
      content.should contain("abstract def server_stream(")
      content.should contain("abstract def client_stream(")
      content.should contain("abstract def bidi(")
      # All dispatch methods present
      content.should contain("dispatch_server_stream")
      content.should contain("dispatch_client_stream")
      content.should contain("dispatch_bidi_stream")
      # Client stub methods present
      content.should contain("def unary(request")
      content.should contain("def server_stream(request")
      content.should contain("def client_stream(requests")
      content.should contain("def bidi(requests")
    end
  end
end
