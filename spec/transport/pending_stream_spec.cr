require "../spec_helper"
require "../support/frame_helpers"

describe GRPC::Transport::PendingStream do
  describe "metadata" do
    it "has no trailers before the first trailer block" do
      stream = GRPC::Transport::PendingStream.new
      stream.begin_header_block
      stream.add_header(":status", "200")
      stream.add_header("x-initial", "one")

      stream.grpc_trailers.empty?.should be_true
    end

    it "tracks initial headers separately from trailing metadata" do
      stream = GRPC::Transport::PendingStream.new
      stream.begin_header_block
      stream.add_header(":status", "200")
      stream.add_header("x-initial", "one")
      stream.begin_header_block
      stream.add_header("grpc-status", "0")
      stream.add_header("x-trailer", "done")

      stream.grpc_headers.get("x-initial").should eq("one")
      stream.grpc_headers.get("x-trailer").should be_nil
      stream.grpc_trailers.get("x-trailer").should eq("done")
    end

    it "keeps grpc status trailers out of metadata" do
      stream = GRPC::Transport::PendingStream.new
      stream.trailers.add("grpc-status", "13")
      stream.trailers.add("grpc-message", "boom")
      stream.trailers.add_bin("grpc-status-details-bin", Bytes[0x01])
      stream.trailers.add("x-extra", "ok")
      stream.trailers.add("x-extra", "second")

      trailers = stream.grpc_trailers
      trailers.get("grpc-status").should be_nil
      trailers.get("grpc-message").should be_nil
      trailers.get("grpc-status-details-bin").should be_nil
      trailers.get_all("x-extra").should eq(["ok", "second"])
    end
  end

  describe "status" do
    it "changes status from UNKNOWN to OK when trailers arrive" do
      stream = GRPC::Transport::PendingStream.new

      stream.grpc_status.code.should eq(GRPC::StatusCode::UNKNOWN)

      stream.begin_header_block
      stream.add_header(":status", "200")
      stream.grpc_status.code.should eq(GRPC::StatusCode::UNKNOWN)

      stream.begin_header_block
      stream.add_header("grpc-status", "0")
      stream.grpc_status.code.should eq(GRPC::StatusCode::OK)
    end

    it "treats missing grpc-status as UNKNOWN" do
      stream = GRPC::Transport::PendingStream.new

      status = stream.grpc_status
      status.code.should eq(GRPC::StatusCode::UNKNOWN)
      status.message.should contain("missing grpc-status")
    end

    it "prefers transport error override over grpc-status when trailers are present" do
      stream = GRPC::Transport::PendingStream.new
      stream.trailers.add("grpc-status", "0")
      stream.transport_error = GRPC::Status.unknown("transport close")

      stream.grpc_status.code.should eq(GRPC::StatusCode::UNKNOWN)
      stream.grpc_status.message.should eq("transport close")
    end
  end

  describe "message delivery" do
    it "hands off coalesced responses outside the connection callback without losing messages" do
      stream = GRPC::Transport::PendingStream.new
      frame = GRPC::Codec.encode(Bytes[1_u8])
      connection_lock = Mutex.new
      consumed = 0
      stream.inbound.consumed = ->(bytes : Int32) {
        connection_lock.synchronize { consumed += bytes }
        nil
      }
      connection_lock.synchronize { 512.times { stream.receive_data(frame) } }
      consumed.should eq(0)
      stream.trailers.add("grpc-status", "0")
      stream.finish
      512.times { stream.messages.receive.should eq(Bytes[1_u8]) }
      stream.messages.receive?.should be_nil
      consumed.should eq(512 * frame.size)
      stream.grpc_status.ok?.should be_true
    end
  end

  describe "invalid responses" do
    it "keeps deframe errors as the final status even with grpc-status" do
      stream = GRPC::Transport::PendingStream.new
      stream.trailers.add("grpc-status", "0")

      stream.receive_data(Bytes[2_u8, 0_u8, 0_u8, 0_u8, 0_u8])

      stream.grpc_status.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
    end

    it "closes message delivery after an unsupported compression flag" do
      stream = GRPC::Transport::PendingStream.new
      # Unsupported compression flag (=2) should become an UNIMPLEMENTED transport error.
      stream.receive_data(Bytes[2_u8, 0_u8, 0_u8, 0_u8, 0_u8])

      stream.messages.receive?.should be_nil
      stream.grpc_status.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
    end

    it "reports an incomplete trailing response frame at end of stream" do
      stream = GRPC::Transport::PendingStream.new
      stream.receive_data(Bytes[0_u8, 0_u8, 0_u8])
      stream.finish

      stream.grpc_status.code.should eq(GRPC::StatusCode::INTERNAL)
      stream.grpc_status.message.should contain("incomplete")
    end

    it "rejects unsupported response encodings before streaming DATA" do
      stream = GRPC::Transport::PendingStream.new
      stream.add_header("grpc-encoding", "snappy")

      stream.grpc_status.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
      stream.messages.receive?.should be_nil
    end

    [0x7ffffffb_u32, 0x80000000_u32, 0xffffffff_u32].each do |length|
      it "reports unrepresentable length #{length} as RESOURCE_EXHAUSTED" do
        stream = GRPC::Transport::PendingStream.new
        stream.receive_data(GrpcFrameSpec.frame_header(0_u8, length))
        stream.messages.receive?.should be_nil
        stream.grpc_status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      end
    end

    [Bytes.empty, Bytes[1, 2, 3]].each do |payload|
      it "reports invalid gzip payload #{payload} as INTERNAL" do
        wire = IO::Memory.new
        wire.write(GrpcFrameSpec.frame_header(1_u8, payload.size.to_u32))
        wire.write(payload)
        stream = GRPC::Transport::PendingStream.new
        stream.add_header("grpc-encoding", "gzip")
        stream.receive_data(wire.to_slice)
        stream.messages.receive?.should be_nil
        stream.grpc_status.code.should eq(GRPC::StatusCode::INTERNAL)
      end
    end

    it "rejects a corrupt gzip trailer as a stream error" do
      wire = GRPC::Codec.encode("checksum".to_slice, compress: true)
      wire[-1] = wire[-1] ^ 0xff_u8
      stream = GRPC::Transport::PendingStream.new
      stream.add_header("grpc-encoding", "gzip")
      stream.receive_data(wire)
      stream.messages.receive?.should be_nil
      stream.grpc_status.code.should eq(GRPC::StatusCode::INTERNAL)
    end
  end

  describe "completion and cancellation" do
    it "publishes completion before the last response is consumed" do
      stream = GRPC::Transport::PendingStream.new
      stream.live_send_buf = GRPC::Transport::LiveSendBuffer.new
      stream.final_status.should be_nil
      stream.receive_data(GRPC::Codec.encode(Bytes[42_u8]))
      stream.trailers.add("grpc-status", "0")
      # Seeing grpc-status while parsing headers is not itself completion.
      stream.final_status.should be_nil
      stream.finish

      stream.final_status.should eq(GRPC::Status.ok)
      ex = expect_raises(GRPC::SendClosedError) { stream.send_outgoing(Bytes[1_u8]) }
      ex.final_status.should eq(GRPC::Status.ok)
      stream.messages.receive.should eq(Bytes[42_u8])
      stream.messages.receive?.should be_nil
    end

    it "distinguishes an active RPC from a completed RPC without grpc-status" do
      stream = GRPC::Transport::PendingStream.new
      stream.final_status.should be_nil
      stream.finish
      stream.final_status.not_nil!.code.should eq(GRPC::StatusCode::UNKNOWN)
    end

    it "keeps the peer failure on a rejected send" do
      stream = GRPC::Transport::PendingStream.new
      stream.live_send_buf = GRPC::Transport::LiveSendBuffer.new
      stream.trailers.add("grpc-status", "14")
      stream.trailers.add("grpc-message", "peer unavailable")
      stream.finish

      ex = expect_raises(GRPC::SendClosedError) { stream.send_outgoing(Bytes[1_u8]) }
      ex.final_status.not_nil!.code.should eq(GRPC::StatusCode::UNAVAILABLE)
      ex.final_status.not_nil!.message.should eq("peer unavailable")
    end

    it "does not treat a request half-close as RPC completion" do
      stream = GRPC::Transport::PendingStream.new
      stream.live_send_buf = GRPC::Transport::LiveSendBuffer.new
      stream.close_send

      stream.final_status.should be_nil
      ex = expect_raises(GRPC::SendClosedError) { stream.send_outgoing(Bytes[1_u8]) }
      ex.final_status.should be_nil
      stream.receive_data(GRPC::Codec.encode(Bytes[2_u8]))
      stream.trailers.add("grpc-status", "0")
      stream.finish
      stream.messages.receive.should eq(Bytes[2_u8])
      stream.messages.receive?.should be_nil
    end

    it "wakes a sender blocked on capacity with the completed RPC status" do
      stream = GRPC::Transport::PendingStream.new
      stream.live_send_buf = GRPC::Transport::LiveSendBuffer.new(1)
      stream.send_outgoing(Bytes[1_u8])
      result = Channel(Exception?).new(1)
      spawn do
        stream.send_outgoing(Bytes[2_u8])
        result.send(nil)
      rescue ex
        result.send(ex)
      end
      Fiber.yield
      select
      when result.receive
        fail "sender did not wait for capacity"
      else
      end
      stream.trailers.add("grpc-status", "0")
      stream.finish

      select
      when ex = result.receive
        ex.should be_a(GRPC::SendClosedError)
        ex.as(GRPC::SendClosedError).final_status.should eq(GRPC::Status.ok)
      when timeout(1.second)
        fail "completion did not wake the blocked sender"
      end
      # The failed second message never entered the queue.
      buffer = Bytes.new(8)
      flags = 0_u32
      stream.live_send_buf.not_nil!.read_into(buffer.to_unsafe, 8_u64, pointerof(flags)).should eq(1)
      buffer[0].should eq(1)
      (flags & LibNghttp2::DATA_FLAG_EOF).should_not eq(0)
    end

    it "does not classify a failure after enqueueing as an unsent message" do
      stream = GRPC::Transport::PendingStream.new
      stream.live_send_buf = GRPC::Transport::LiveSendBuffer.new
      stream.send_resume_proc = -> { raise IO::Error.new("resume failed"); nil }
      expect_raises(IO::Error, "resume failed") { stream.send_outgoing(Bytes[1_u8]) }
    end

    it "publishes local cancellation without replacing an earlier completion" do
      stream = GRPC::Transport::PendingStream.new
      stream.live_send_buf = GRPC::Transport::LiveSendBuffer.new
      stream.cancel
      stream.final_status.not_nil!.code.should eq(GRPC::StatusCode::CANCELLED)
      ex = expect_raises(GRPC::SendClosedError) { stream.send_outgoing(Bytes[1_u8]) }
      ex.final_status.not_nil!.code.should eq(GRPC::StatusCode::CANCELLED)

      completed = GRPC::Transport::PendingStream.new
      completed.trailers.add("grpc-status", "0")
      completed.finish
      completed.cancel
      completed.final_status.should eq(GRPC::Status.ok)
    end

    it "finishes only once" do
      stream = GRPC::Transport::PendingStream.new

      stream.finish
      stream.finish

      stream.messages.receive?.should be_nil
    end

    it "ignores transport errors reported after finish" do
      stream = GRPC::Transport::PendingStream.new
      stream.trailers.add("grpc-status", "0")

      stream.finish
      stream.transport_error = GRPC::Status.unknown("late close")

      stream.grpc_status.code.should eq(GRPC::StatusCode::OK)
    end

    it "ignores DATA that races with local cancellation" do
      stream = GRPC::Transport::PendingStream.new
      stream.cancel_proc = -> { nil }
      stream.cancel

      stream.receive_data(GRPC::Codec.encode(Bytes[1_u8]))
      stream.messages.receive?.should be_nil
    end

    ["data", "header"].each do |source|
      it "resets a malformed #{source} stream after releasing the connection callback lock" do
        stream = GRPC::Transport::PendingStream.new
        connection_lock = Mutex.new
        cancelled = Channel(Nil).new(1)
        stream.cancel_proc = -> {
          connection_lock.synchronize { cancelled.send(nil) }
          nil
        }
        connection_lock.synchronize do
          if source == "header"
            stream.add_header("grpc-encoding", "unsupported")
          else
            stream.receive_data(GrpcFrameSpec.frame_header(2_u8, 0_u32))
          end
        end
        select
        when cancelled.receive
        when timeout(1.second)
          fail "malformed stream was not reset outside the connection callback"
        end
        stream.grpc_status.code.should eq(GRPC::StatusCode::UNIMPLEMENTED)
      end
    end
  end
end
