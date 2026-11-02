require "./spec_helper"
require "./interop/generated/google/protobuf/wrappers.pb"
require "./interop/generated/peer.grpc"

# Explicit entry point: a missing reference server must fail, never skip CI.
private def with_go_peer(tls : Bool, &)
  args = tls ? ["-cert", "spec/test.crt", "-key", "spec/test.key"] : [] of String
  process = Process.new("./bin/grpc-go-peer", args, output: Process::Redirect::Pipe, error: Process::Redirect::Inherit)
  begin
    ready = Channel(String?).new(1)
    spawn { ready.send(process.output.gets) }
    address = select
    when line = ready.receive
      line || raise "grpc-go peer exited before becoming ready"
    when timeout(5.seconds)
      raise "grpc-go peer did not announce readiness"
    end
    context = OpenSSL::SSL::Context::Client.new
    context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    channel = GRPC::Channel.new("#{tls ? "https" : "http"}://#{address}", tls_context: context)
    yield Interop::Peer::Client.new(channel), channel
  ensure
    channel.try &.close
    process.terminate unless process.terminated?
    process.wait
  end
end

private def packet(bytes : Bytes = Bytes.empty) : Google::Protobuf::BytesValue
  Google::Protobuf::BytesValue.new.tap(&.value=(bytes))
end

private def rpc_context : GRPC::ClientContext
  GRPC::ClientContext.new(deadline: 5.seconds)
end

{false, true}.each do |tls|
  describe "Crystal client / grpc-go server (TLS=#{tls})" do
    it "exchanges empty and large gzip messages with binary metadata" do
      with_go_peer(tls) do |client, _channel|
        {Bytes.empty, Bytes.new(256 * 1024) { |i| (i % 251).to_u8 }}.each do |bytes|
          metadata = GRPC::Metadata.new
          metadata.add("grpc-encoding", "gzip")
          metadata.add_bin("echo-bin", Bytes[0, 128, 255])
          response = client.echo_response(packet(bytes), GRPC::ClientContext.new(metadata: metadata, deadline: 5.seconds))
          response.ok!.value.should eq(bytes)
          response.initial_metadata.get("x-peer").should eq("grpc-go")
          response.trailing_metadata.get_bin("echo-bin").should eq(Bytes[0, 128, 255])
        end
      end
    end

    it "receives large server-streamed messages across HTTP/2 windows" do
      with_go_peer(tls) do |client, _channel|
        bytes = Bytes.new(128 * 1024, 42_u8)
        stream = client.watch(packet(bytes), rpc_context)
        count = 0
        stream.each do |message|
          message.value.should eq(bytes)
          count += 1
        end
        count.should eq(16)
        stream.status.should eq(GRPC::Status.ok)
      end
    end

    it "half-closes a client stream and decodes exactly one response" do
      with_go_peer(tls) do |client, _channel|
        stream = client.upload(rpc_context)
        3.times { |i| stream.send(packet(Bytes[i.to_u8])) }
        stream.close_and_recv.value.should eq(Bytes[0, 1, 2])
      end
    end

    it "interleaves bidi sends and replies before half-close" do
      with_go_peer(tls) do |client, _channel|
        call = client.chat(rpc_context)
        received = Channel(Bytes).new
        done = Channel(Exception?).new(1)
        spawn do
          call.each { |reply| received.send(reply.value) }
          done.send(nil)
        rescue ex
          done.send(ex)
        end
        8.times do |i|
          bytes = Bytes[i.to_u8]
          call.send(packet(bytes))
          select
          when reply = received.receive
            reply.should eq(bytes)
          when timeout(5.seconds)
            fail "bidi reply required request half-close"
          end
        end
        call.close_send
        select
        when error = done.receive
          raise error if error
        when timeout(5.seconds)
          fail "bidi iterator did not finish"
        end
        call.final_status.should eq(GRPC::Status.ok)
      end
    end

    it "reuses the sole stream slot after repeated server-initiated bidi completion" do
      with_go_peer(tls) do |client, _channel|
        20.times do |i|
          call = client.finish(rpc_context)
          call.send(packet(Bytes[i.to_u8]))
          call.map(&.value).should eq([Bytes[i.to_u8]])
          call.final_status.should eq(GRPC::Status.ok)
          expect_raises(GRPC::SendClosedError) { call.send(packet) }
        end
        client.echo(packet, rpc_context).value.should be_empty
      end
    end

    it "preserves Unicode error messages and reuses the connection after a deadline and cancellation" do
      with_go_peer(tls) do |client, _channel|
        message = "日本語 é α % +"
        response = client.fail_response(packet(message.to_slice), rpc_context)
        response.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
        response.status.message.should eq(message)
        response = client.wait_response(packet, GRPC::ClientContext.new(deadline: 100.milliseconds))
        response.status.code.should eq(GRPC::StatusCode::DEADLINE_EXCEEDED)
        call = client.chat(rpc_context)
        call.cancel
        call.final_status.try(&.code).should eq(GRPC::StatusCode::CANCELLED)
        client.echo(packet(Bytes[7]), rpc_context).value.should eq(Bytes[7])
      end
    end
  end
end
