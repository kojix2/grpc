require "../spec_helper"
require "../support/integration_helpers"

describe "GRPC live client streaming" do
  it "sends messages incrementally before close_and_recv" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      raw = channel.open_client_stream_live("test.StreamingEcho", "ClientStream")
      raw.send_raw(TestProto.encode_string("hello"))
      raw.send_raw(TestProto.encode_string("world"))
      body = raw.close_and_recv
      result = TestProto.decode_string(body)
      result.should eq("joined:hello,world")
      raw.status.ok?.should be_true
    ensure
      channel.close
      server.stop
    end
  end

  it "close_and_recv with no messages returns server response" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle StreamingEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      raw = channel.open_client_stream_live("test.StreamingEcho", "ClientStream")
      body = raw.close_and_recv
      result = TestProto.decode_string(body)
      result.should eq("joined:")
      raw.status.ok?.should be_true
    ensure
      channel.close
      server.stop
    end
  end
end

describe "GRPC full-duplex bidi streaming" do
  it "interleaves sends and receives in the same stream" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle FullDuplexEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      raw = channel.open_bidi_stream_live("test.FullDuplexEcho", "EchoStream")
      received = [] of String
      done = ::Channel(Nil).new(1)

      # Receiver fiber runs concurrently with the sender
      spawn do
        raw.each { |bytes| received << TestProto.decode_string(bytes) }
        done.send(nil)
      end

      # Send 3 messages then close; server echoes them back after close_send
      raw.send_raw(TestProto.encode_string("a"))
      raw.send_raw(TestProto.encode_string("b"))
      raw.send_raw(TestProto.encode_string("c"))
      raw.close_send

      done.receive
      received.should eq(["a", "b", "c"])
      raw.status.ok?.should be_true
    ensure
      channel.close
      server.stop
    end
  end

  it "close_send without messages completes cleanly" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle FullDuplexEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      raw = channel.open_bidi_stream_live("test.FullDuplexEcho", "EchoStream")
      raw.close_send
      received = [] of Bytes
      raw.each { |bytes| received << bytes }
      received.should be_empty
      raw.status.ok?.should be_true
    ensure
      channel.close
      server.stop
    end
  end

  it "continues delivering messages after an idle gap before close_send" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle FullDuplexEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      raw = channel.open_bidi_stream_live("test.FullDuplexEcho", "EchoStream")
      received = [] of String
      done = ::Channel(Nil).new(1)

      spawn do
        raw.each { |bytes| received << TestProto.decode_string(bytes) }
        done.send(nil)
      end

      raw.send_raw(TestProto.encode_string("alpha"))
      sleep 200.milliseconds
      raw.send_raw(TestProto.encode_string("beta"))
      raw.send_raw(TestProto.encode_string("gamma"))
      raw.close_send

      done.receive
      received.should eq(["alpha", "beta", "gamma"])
      raw.status.ok?.should be_true
    ensure
      channel.close
      server.stop
    end
  end

  it "continues delivering messages after an earlier deadline-exceeded unary call" do
    deadline_port = find_free_port
    deadline_server = GRPC::Server.new
    deadline_server.handle DeadlineProbeService.new
    deadline_server.bind("127.0.0.1:#{deadline_port}")
    deadline_server.start
    deadline_channel = GRPC::Channel.new("127.0.0.1:#{deadline_port}")

    begin
      ctx = GRPC::ClientContext.new(deadline: 30.milliseconds)
      response = deadline_channel.unary_call("test.DeadlineProbe", "SlowUnary", Bytes.empty, ctx)
      response.status.ok?.should be_false
      response.status.code.should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
    ensure
      deadline_channel.close
      deadline_server.stop
    end

    bidi_port = find_free_port
    bidi_server = GRPC::Server.new
    bidi_server.handle FullDuplexEchoService.new
    bidi_server.bind("127.0.0.1:#{bidi_port}")
    bidi_server.start
    bidi_channel = GRPC::Channel.new("127.0.0.1:#{bidi_port}")

    begin
      raw = bidi_channel.open_bidi_stream_live("test.FullDuplexEcho", "EchoStream")
      received = [] of String
      done = ::Channel(Nil).new(1)

      spawn do
        raw.each { |bytes| received << TestProto.decode_string(bytes) }
        done.send(nil)
      end

      raw.send_raw(TestProto.encode_string("alpha"))
      sleep 200.milliseconds
      raw.send_raw(TestProto.encode_string("beta"))
      raw.send_raw(TestProto.encode_string("gamma"))
      raw.close_send

      done.receive
      received.should eq(["alpha", "beta", "gamma"])
      raw.status.ok?.should be_true
    ensure
      bidi_channel.close
      bidi_server.stop
    end
  end

  it "fails unknown bidi streams without waiting for close_send" do
    port = find_free_port
    server = GRPC::Server.new
    server.handle FullDuplexEchoService.new
    server.bind("127.0.0.1:#{port}")
    server.start
    channel = GRPC::Channel.new("127.0.0.1:#{port}")

    begin
      raw = channel.open_bidi_stream_live("missing.Service", "MissingMethod")
      done = ::Channel(Nil).new(1)

      spawn do
        raw.each { |_bytes| }
        done.send(nil)
      end

      raw.send_raw(TestProto.encode_string("probe"))

      select
      when done.receive
      when timeout(1.second)
        fail "unknown bidi stream did not fail before close_send"
      end

      raw.status.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
    ensure
      channel.close
      server.stop
    end
  end
end
