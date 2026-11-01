require "../spec_helper"
require "../support/integration_helpers"

describe "HTTP/2 RPCs" do
  describe "unary" do
    it "performs a unary RPC round-trip" do
      port = find_free_port
      server = start_test_server(port)
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        req_bytes = TestProto.encode_string("hello")
        response = channel.unary_call("test.Echo", "Echo", req_bytes)

        response.status.ok?.should be_true
        TestProto.decode_string(response.raw).should eq("echo:hello")
      ensure
        channel.close
        server.stop
      end
    end
  end

  describe "server streaming" do
    it "performs a server-streaming RPC" do
      port = find_free_port
      server = GRPC::Server.new
      server.handle StreamingEchoService.new
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        req_bytes = TestProto.encode_string("hello")
        stream = channel.open_server_stream("test.StreamingEcho", "ServerStream", req_bytes)
        messages = [] of String
        stream.each do |bytes|
          messages << TestProto.decode_string(bytes)
        end
        stream.status.ok?.should be_true
        messages.size.should eq(3)
        messages[0].should eq("0:hello")
        messages[1].should eq("1:hello")
        messages[2].should eq("2:hello")
      ensure
        channel.close
        server.stop
      end
    end
  end

  describe "client streaming" do
    it "performs a client-streaming RPC" do
      port = find_free_port
      server = GRPC::Server.new
      server.handle StreamingEchoService.new
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        messages = [
          TestProto.encode_string("a"),
          TestProto.encode_string("b"),
          TestProto.encode_string("c"),
        ]
        call = channel.open_client_stream_live("test.StreamingEcho", "ClientStream")
        messages.each { |msg| call.send_raw(msg) }
        body = call.close_and_recv
        status = call.status
        status.ok?.should be_true
        TestProto.decode_string(body).should eq("joined:a,b,c")
      ensure
        channel.close
        server.stop
      end
    end

    it "delivers client-streaming requests to the server before close_and_recv" do
      port = find_free_port
      first_seen = ::Channel(String).new(1)
      server = GRPC::Server.new
      server.handle LiveProbeService.new(first_seen)
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        call = channel.open_client_stream_live("test.LiveProbe", "ClientStreamLive")
        call.send_raw(TestProto.encode_string("first"))

        select
        when seen = first_seen.receive
          seen.should eq("first")
        when timeout(1.second)
          fail "server did not observe first streamed request before close_and_recv"
        end

        call.send_raw(TestProto.encode_string("second"))
        body = call.close_and_recv
        call.status.ok?.should be_true
        TestProto.decode_string(body).should eq("count:2")
      ensure
        channel.close
        server.stop
      end
    end

    it "client-streaming RPC with zero messages returns a response" do
      port = find_free_port
      server = GRPC::Server.new
      server.handle StreamingEchoService.new
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        call = channel.open_client_stream_live("test.StreamingEcho", "ClientStream")
        body = call.close_and_recv
        status = call.status
        status.ok?.should be_true
        TestProto.decode_string(body).should eq("joined:")
      ensure
        channel.close
        server.stop
      end
    end
  end

  describe "bidirectional streaming" do
    it "performs a bidirectional streaming RPC" do
      port = find_free_port
      server = GRPC::Server.new
      server.handle StreamingEchoService.new
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        messages = [
          TestProto.encode_string("x"),
          TestProto.encode_string("y"),
        ]
        stream = channel.open_bidi_stream_live("test.StreamingEcho", "BidiStream")
        messages.each { |msg| stream.send_raw(msg) }
        stream.close_send
        replies = [] of String
        stream.each { |bytes| replies << TestProto.decode_string(bytes) }
        stream.status.ok?.should be_true
        replies.size.should eq(2)
        replies[0].should eq("reply0:x")
        replies[1].should eq("reply1:y")
      ensure
        channel.close
        server.stop
      end
    end

    it "delivers bidi requests live before client closes the stream" do
      port = find_free_port
      server = GRPC::Server.new
      server.handle StreamingEchoService.new
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        call = channel.open_bidi_stream_live("test.StreamingEcho", "BidiStream")
        replies = ::Channel(String).new(8)
        done = ::Channel(Nil).new(1)

        spawn do
          begin
            call.each { |bytes| replies.send(TestProto.decode_string(bytes)) }
          ensure
            done.send(nil) rescue nil
          end
        end

        call.send_raw(TestProto.encode_string("x"))
        select
        when first_reply = replies.receive
          first_reply.should eq("reply0:x")
        when timeout(1.second)
          fail "server did not emit first bidi reply before close_send"
        end

        call.send_raw(TestProto.encode_string("y"))
        call.close_send

        second_reply = replies.receive
        second_reply.should eq("reply1:y")

        select
        when done.receive
        when timeout(1.second)
          fail "bidi receive loop did not finish"
        end

        call.status.ok?.should be_true
      ensure
        channel.close
        server.stop
      end
    end
  end

  describe "service routing" do
    it "routes requests to the correct service when multiple services are registered" do
      port = find_free_port
      server = GRPC::Server.new
      server.handle EchoService.new
      server.handle StreamingEchoService.new
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        # Call EchoService
        response = channel.unary_call("test.Echo", "Echo", TestProto.encode_string("ping"))
        response.status.ok?.should be_true
        TestProto.decode_string(response.raw).should eq("echo:ping")

        # Call StreamingEchoService on the same channel/server
        msgs = [TestProto.encode_string("a"), TestProto.encode_string("b")]
        call = channel.open_client_stream_live("test.StreamingEcho", "ClientStream")
        msgs.each { |msg| call.send_raw(msg) }
        body = call.close_and_recv
        status = call.status
        status.ok?.should be_true
        TestProto.decode_string(body).should eq("joined:a,b")
      ensure
        channel.close
        server.stop
      end
    end
  end

  describe "error propagation" do
    it "returns the correct gRPC error status on service error" do
      port = find_free_port
      server = start_test_server(port)
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        response = channel.unary_call("test.Echo", "Fail", Bytes.empty)
        response.status.ok?.should be_false
        response.status.code.should eq(GRPC::StatusCode::NOT_FOUND)
        response.status.message.should eq("not here")
      ensure
        channel.close
        server.stop
      end
    end

    it "returns UNIMPLEMENTED for unknown service" do
      port = find_free_port
      server = start_test_server(port)
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        response = channel.unary_call("no.Such", "Nope", Bytes.empty)
        response.status.ok?.should be_false
        response.status.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
      ensure
        channel.close
        server.stop
      end
    end

    it "error status returned from dispatch_server_stream reaches the client" do
      port = find_free_port
      server = GRPC::Server.new
      server.handle StreamingEchoService.new
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        stream = channel.open_server_stream("test.StreamingEcho", "ErrorStream", Bytes.empty)
        stream.each { } # drain (no messages expected)
        stream.status.ok?.should be_false
        stream.status.code.should eq(GRPC::StatusCode::INTERNAL)
        stream.status.message.should eq("forced stream error")
      ensure
        channel.close
        server.stop
      end
    end

    it "preserves streamed messages emitted before a server-side stream error" do
      port = find_free_port
      server = GRPC::Server.new
      server.handle StreamingEchoService.new
      server.bind("127.0.0.1:#{port}")
      server.start
      channel = GRPC::Channel.new("127.0.0.1:#{port}")

      begin
        req = TestProto.encode_string("batch")
        stream = channel.open_server_stream("test.StreamingEcho", "PartialErrorStream", req)
        messages = [] of String
        stream.each { |bytes| messages << TestProto.decode_string(bytes) }

        messages.should eq(["partial0:batch", "partial1:batch", "partial2:batch"])
        stream.status.ok?.should be_false
        stream.status.code.should eq(GRPC::StatusCode::INTERNAL)
        stream.status.message.should eq("forced partial stream error")
      ensure
        channel.close
        server.stop
      end
    end
  end
end
