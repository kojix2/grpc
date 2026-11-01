require "../spec_helper"
require "../support/malformed_peer"

describe "malformed streamed responses over HTTP/2" do
  {"Length" => GRPC::StatusCode::RESOURCE_EXHAUSTED,
   "Flag"   => GRPC::StatusCode::UNIMPLEMENTED,
   "Gzip"   => GRPC::StatusCode::INTERNAL}.each do |method, expected|
    it "isolates #{method} errors while leaving the connection usable" do
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.local_address.port
      listener.close
      factory = ->(io : IO, services : Hash(String, GRPC::Service), interceptors : Array(GRPC::ServerInterceptor), peer : String, tls : OpenSSL::SSL::Socket::Server?) {
        MalformedFrameConnection.new(io, services, interceptors, peer, tls).as(GRPC::Transport::ServerTransport)
      }
      server = GRPC::Server.new(transport_factory: factory)
      server.handle(MalformedFrameService.new)
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")
      context = GRPC::ClientContext.new(deadline: Time.utc + 5.seconds)
      stream = channel.open_server_stream("test.MalformedFrame", method, Bytes.empty, context)
      stream.each { |_message| fail "malformed peer emitted a valid message" }
      stream.status.code.should eq(expected)
      reply = channel.unary_call("test.MalformedFrame", "Echo", Bytes[7], context)
      reply.status.ok?.should be_true
      reply.raw.should eq(Bytes[7])
    ensure
      channel.try(&.close)
      server.try(&.stop)
    end
  end
end
