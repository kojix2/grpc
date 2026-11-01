require "../spec_helper"
require "../support/integration_helpers"
require "../support/interceptors"

describe "GRPC client interceptors" do
  it "wraps a unary call and records before/after events" do
    port = find_free_port
    server = start_test_server(port)
    interceptor = RecordingClientInterceptor.new
    channel = GRPC::Channel.new("127.0.0.1:#{port}",
      interceptors: [interceptor] of GRPC::ClientInterceptor)

    begin
      response = channel.unary_call("test.Echo", "Echo", TestProto.encode_string("hi"))
      response.status.ok?.should be_true
      TestProto.decode_string(response.raw).should eq("echo:hi")
      interceptor.calls.should eq(["before:/test.Echo/Echo", "after:/test.Echo/Echo"])
    ensure
      channel.close
      server.stop
    end
  end

  it "chains multiple client interceptors outermost-first" do
    port = find_free_port
    server = start_test_server(port)
    first = RecordingClientInterceptor.new
    second = RecordingClientInterceptor.new
    channel = GRPC::Channel.new("127.0.0.1:#{port}",
      interceptors: [first, second] of GRPC::ClientInterceptor)

    begin
      response = channel.unary_call("test.Echo", "Echo", TestProto.encode_string("x"))
      response.status.ok?.should be_true
      # first wraps second: first.before → second.before → RPC → second.after → first.after
      first.calls.should eq(["before:/test.Echo/Echo", "after:/test.Echo/Echo"])
      second.calls.should eq(["before:/test.Echo/Echo", "after:/test.Echo/Echo"])
    ensure
      channel.close
      server.stop
    end
  end
end

describe "GRPC streaming client interceptors" do
  it "intercepts a server-streaming RPC" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    interceptor = FullRecordingClientInterceptor.new
    channel = GRPC::Channel.new("127.0.0.1:#{port}",
      interceptors: [interceptor] of GRPC::ClientInterceptor)

    begin
      stream = channel.open_server_stream("test.StreamingEcho", "ServerStream",
        TestProto.encode_string("hi"))
      messages = [] of String
      stream.each { |bytes| messages << TestProto.decode_string(bytes) }
      stream.status.ok?.should be_true
      messages.size.should eq(3)
      interceptor.calls.should eq([
        "ss:before:/test.StreamingEcho/ServerStream",
        "ss:after:/test.StreamingEcho/ServerStream",
      ])
    ensure
      channel.close
      server.stop
    end
  end

  it "intercepts a client-streaming RPC" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    interceptor = FullRecordingClientInterceptor.new
    channel = GRPC::Channel.new("127.0.0.1:#{port}",
      interceptors: [interceptor] of GRPC::ClientInterceptor)

    begin
      msgs = [TestProto.encode_string("a"), TestProto.encode_string("b")]
      call = channel.open_client_stream_live("test.StreamingEcho", "ClientStream")
      msgs.each { |msg| call.send_raw(msg) }
      body = call.close_and_recv
      status = call.status
      status.ok?.should be_true
      TestProto.decode_string(body).should eq("joined:a,b")
      interceptor.calls.should eq([
        "cs:before:/test.StreamingEcho/ClientStream",
        "cs:after:/test.StreamingEcho/ClientStream",
      ])
    ensure
      channel.close
      server.stop
    end
  end

  it "intercepts a bidirectional-streaming RPC" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    interceptor = FullRecordingClientInterceptor.new
    channel = GRPC::Channel.new("127.0.0.1:#{port}",
      interceptors: [interceptor] of GRPC::ClientInterceptor)

    begin
      msgs = [TestProto.encode_string("x")]
      stream = channel.open_bidi_stream_live("test.StreamingEcho", "BidiStream")
      msgs.each { |msg| stream.send_raw(msg) }
      stream.close_send
      replies = [] of String
      stream.each { |bytes| replies << TestProto.decode_string(bytes) }
      stream.status.ok?.should be_true
      replies.should eq(["reply0:x"])
      interceptor.calls.should eq([
        "bidi:before:/test.StreamingEcho/BidiStream",
        "bidi:after:/test.StreamingEcho/BidiStream",
      ])
    ensure
      channel.close
      server.stop
    end
  end
end

describe "GRPC server interceptors" do
  it "blocks a call when authorization is missing" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle EchoService.new
    server.intercept AuthServerInterceptor.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      response = channel.unary_call("test.Echo", "Echo", TestProto.encode_string("hi"))
      response.status.ok?.should be_false
      response.status.code.should eq(GRPC::StatusCode::UNAUTHENTICATED)
      response.status.message.should eq("invalid token")
    ensure
      channel.close
      server.stop
    end
  end

  it "allows a call through when authorization is valid" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle EchoService.new
    server.intercept AuthServerInterceptor.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      ctx = GRPC::ClientContext.new(metadata: {"authorization" => "valid-token"})
      response = channel.unary_call("test.Echo", "Echo", TestProto.encode_string("hello"), ctx)
      response.status.ok?.should be_true
      TestProto.decode_string(response.raw).should eq("echo:hello")
    ensure
      channel.close
      server.stop
    end
  end

  it "records before/after events on server interceptor" do
    port = find_free_port
    interceptor = RecordingServerInterceptor.new
    server = GRPC::Server.new
    server.handle EchoService.new
    server.intercept interceptor
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      response = channel.unary_call("test.Echo", "Echo", TestProto.encode_string("test"))
      response.status.ok?.should be_true
      interceptor.calls.should eq(["before:Echo", "after:Echo"])
    ensure
      channel.close
      server.stop
    end
  end
end

describe "GRPC streaming server interceptors" do
  it "intercepts a server-streaming RPC" do
    port = find_free_port
    interceptor = FullRecordingServerInterceptor.new
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.intercept interceptor
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      stream = channel.open_server_stream("test.StreamingEcho", "ServerStream",
        TestProto.encode_string("hi"))
      messages = [] of String
      stream.each { |bytes| messages << TestProto.decode_string(bytes) }
      stream.status.ok?.should be_true
      messages.size.should eq(3)
      interceptor.calls.should eq(["ss:before:ServerStream", "ss:after:ServerStream"])
    ensure
      channel.close
      server.stop
    end
  end

  it "intercepts a client-streaming RPC" do
    port = find_free_port
    interceptor = FullRecordingServerInterceptor.new
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.intercept interceptor
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      msgs = [TestProto.encode_string("a"), TestProto.encode_string("b")]
      call = channel.open_client_stream_live("test.StreamingEcho", "ClientStream")
      msgs.each { |msg| call.send_raw(msg) }
      body = call.close_and_recv
      status = call.status
      status.ok?.should be_true
      TestProto.decode_string(body).should eq("joined:a,b")
      interceptor.calls.should eq(["cs:before:ClientStream", "cs:after:ClientStream"])
    ensure
      channel.close
      server.stop
    end
  end

  it "intercepts a bidirectional-streaming RPC" do
    port = find_free_port
    interceptor = FullRecordingServerInterceptor.new
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.intercept interceptor
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      msgs = [TestProto.encode_string("x")]
      stream = channel.open_bidi_stream_live("test.StreamingEcho", "BidiStream")
      msgs.each { |msg| stream.send_raw(msg) }
      stream.close_send
      replies = [] of String
      stream.each { |bytes| replies << TestProto.decode_string(bytes) }
      stream.status.ok?.should be_true
      replies.should eq(["reply0:x"])
      interceptor.calls.should eq(["bidi:before:BidiStream", "bidi:after:BidiStream"])
    ensure
      channel.close
      server.stop
    end
  end
end
