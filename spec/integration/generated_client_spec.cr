require "../spec_helper"
require "../support/integration_helpers"
require "../fixtures/generator/collisions.pb"
require "../fixtures/generator/collisions.grpc"

# These fixtures are generated from a schema accepted by protoc. Instantiating
# each RPC also checks the method bodies Crystal does not type-check eagerly.
private class GeneratedCollisionService < GeneratorCollisions::Echo::Service
  private def reply(value : Int32) : GeneratorCollisions::Client
    result = GeneratorCollisions::Client.new
    result.value = value
    result
  end

  def foo(request : GeneratorCollisions::Service, ctx : GRPC::ServerContext) : GeneratorCollisions::Client
    reply(request.value)
  end

  def foo_response(request : GeneratorCollisions::Service, ctx : GRPC::ServerContext) : GeneratorCollisions::Client
    reply(request.value + 1)
  end

  def foo_response_2(request : GeneratorCollisions::Service, ctx : GRPC::ServerContext) : GeneratorCollisions::Client
    reply(request.value + 2)
  end

  def watch(request : GeneratorCollisions::Service, writer : GRPC::ResponseStream(GeneratorCollisions::Client), ctx : GRPC::ServerContext) : GRPC::Status
    3.times { |i| writer.send(reply(request.value + i)) }
    GRPC::Status.ok
  end

  def upload(requests : GRPC::RequestStream(GeneratorCollisions::Service), ctx : GRPC::ServerContext) : GeneratorCollisions::Client
    reply(requests.sum(&.value))
  end

  def chat(requests : GRPC::RequestStream(GeneratorCollisions::Service), writer : GRPC::ResponseStream(GeneratorCollisions::Client), ctx : GRPC::ServerContext) : GRPC::Status
    requests.each { |request| writer.send(reply(request.value)) }
    GRPC::Status.ok
  end
end

describe "GRPC generated clients" do
  it "runs every RPC shape with shadowing message names and colliding unary helper names" do
    server = GRPC::Server.new
    server.handle(GeneratedCollisionService.new)
    port = find_free_port
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    client = GeneratorCollisions::Echo::Client.new(channel)
    request = GeneratorCollisions::Service.new
    request.value = 7
    client.foo(request).value.should eq(7)
    client.foo_response_3(request).ok!.value.should eq(7)
    client.foo_response(request).value.should eq(8)
    client.foo_response_2(request).value.should eq(9)

    stream = client.watch(request)
    stream.map(&.value).should eq([7, 8, 9])
    stream.status.should eq(GRPC::Status.ok)

    upload = client.upload
    2.times { upload.send(request) }
    upload.close_and_recv.value.should eq(14)

    chat = client.chat
    chat.send(request)
    chat.close_send
    chat.map(&.value).should eq([7])
    chat.final_status.should eq(GRPC::Status.ok)
  ensure
    channel.try &.close
    server.try &.stop
  end
end
