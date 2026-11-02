require "../spec_helper"

describe GRPC::ServerStream(Int32) do
  describe "metadata" do
    it "returns empty headers and trailers in initial state" do
      stream = GRPC::ServerStream(Int32).new
      stream.headers.empty?.should be_true
      stream.trailers.empty?.should be_true
    end
  end

  describe "completion and cancellation" do
    it "invokes cancel callback only once" do
      cancels = 0
      stream = GRPC::ServerStream(Int32).new(
        -> { GRPC::Metadata.new },
        -> { GRPC::Status.ok },
        -> { GRPC::Metadata.new },
        -> { cancels += 1; nil }
      )

      stream.cancel
      stream.cancel

      cancels.should eq(1)
    end
  end
end

describe GRPC::ClientStream(Int32, Int32) do
  describe "metadata" do
    it "returns empty headers and trailers in initial state" do
      result = ::Channel(Int32 | Exception).new(1)
      call = GRPC::ClientStream(Int32, Int32).new(
        ->(_msg : Int32) { nil },
        -> { nil },
        result
      )
      call.headers.empty?.should be_true
      call.trailers.empty?.should be_true
    end
  end

  describe "completion and cancellation" do
    it "invokes cancel callback only once" do
      cancels = 0
      result = ::Channel(Int32 | Exception).new(1)
      call = GRPC::ClientStream(Int32, Int32).new(
        ->(_msg : Int32) { nil },
        -> { nil },
        result,
        -> { GRPC::Metadata.new },
        -> { GRPC::Status.ok },
        -> { GRPC::Metadata.new },
        -> { cancels += 1; nil }
      )

      call.cancel
      call.cancel

      cancels.should eq(1)
    end
  end
end

describe GRPC::BidiCall(Int32, Int32) do
  it "exposes transport completion while decoded replies are still queued" do
    recv = Channel(Int32 | Exception).new(1)
    recv.send(7)
    final = nil.as(GRPC::Status?)
    call = GRPC::BidiCall(Int32, Int32).new(
      ->(_msg : Int32) { nil }, -> { nil }, recv,
      final_status_proc: -> { final })

    call.final_status.should be_nil
    final = GRPC::Status.ok
    call.final_status.should eq(GRPC::Status.ok)
    recv.close
    call.to_a.should eq([7])
  end

  describe "metadata" do
    it "returns empty headers and trailers in initial state" do
      recv = ::Channel(Int32 | Exception).new(1)
      call = GRPC::BidiCall(Int32, Int32).new(
        ->(_msg : Int32) { nil },
        -> { nil },
        recv
      )
      call.headers.empty?.should be_true
      call.trailers.empty?.should be_true
    end
  end

  describe "completion and cancellation" do
    it "invokes cancel callback only once" do
      cancels = 0
      recv = ::Channel(Int32 | Exception).new(1)
      call = GRPC::BidiCall(Int32, Int32).new(
        ->(_msg : Int32) { nil },
        -> { nil },
        recv,
        -> { GRPC::Metadata.new },
        -> { GRPC::Status.ok },
        -> { GRPC::Metadata.new },
        -> { cancels += 1; nil }
      )

      call.cancel
      call.cancel

      cancels.should eq(1)
    end
  end
end

private class IdentityBytesMarshaller < GRPC::Marshaller(Bytes)
  getter decodes = 0

  def encode(value : Bytes) : Bytes
    value
  end

  def decode(bytes : Bytes) : Bytes
    @decodes += 1
    bytes
  end
end

{false, true}.each do |bidi|
  describe (bidi ? "typed bidirectional receive" : "typed server-streaming receive") do
    it "keeps unconsumed responses within the transport byte budget" do
      pending = GRPC::Transport::PendingStream.new(GRPC::ReceiveLimits.new(max_buffered_bytes: 32))
      marshaller = IdentityBytesMarshaller.new
      stream = if bidi
                 raw = GRPC::RawBidiCall.new(->(_b : Bytes) { }, -> { }, pending.messages,
                   -> { pending.grpc_headers }, -> { pending.grpc_status }, -> { pending.grpc_trailers }, -> { pending.cancel })
                 GRPC::BidiCall(Bytes, Bytes).new(raw, marshaller, marshaller)
               else
                 raw = GRPC::RawServerStream.build(pending.messages, status_proc: -> { pending.grpc_status }, cancel_proc: -> { pending.cancel })
                 GRPC::ServerStream(Bytes).new(raw, marshaller)
               end
      2.times { pending.receive_data(GRPC::Codec.encode(Bytes.new(16))) }
      Fiber.yield
      marshaller.decodes.should eq(0)
      pending.receive_data(GRPC::Codec.encode(Bytes.new(16)))
      stream.status.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      stream.cancel
    end

    it "cancels an unread raw handoff without a forwarding fiber" do
      pending = GRPC::Transport::PendingStream.new
      marshaller = IdentityBytesMarshaller.new
      stream = if bidi
                 raw = GRPC::RawBidiCall.new(->(_b : Bytes) { }, -> { }, pending.messages,
                   -> { pending.grpc_headers }, -> { pending.grpc_status }, -> { pending.grpc_trailers }, -> { pending.cancel })
                 GRPC::BidiCall(Bytes, Bytes).new(raw, marshaller, marshaller)
               else
                 raw = GRPC::RawServerStream.build(pending.messages, status_proc: -> { pending.grpc_status }, cancel_proc: -> { pending.cancel })
                 GRPC::ServerStream(Bytes).new(raw, marshaller)
               end
      129.times { pending.receive_data(GRPC::Codec.encode(Bytes[42])) }
      Fiber.yield
      stream.cancel
      stream.to_a.should be_empty
      stream.status.code.should eq(GRPC::StatusCode::CANCELLED)
      marshaller.decodes.should eq(0)
    end
  end
end

describe GRPC::ServerStream(Int32) do
  it "unblocks a producer waiting on the legacy typed queue when cancelled" do
    stream = GRPC::ServerStream(Int32).new(status_proc: -> { GRPC::Status.cancelled })
    128.times { stream.push(1) }
    done = Channel(Nil).new(1)
    spawn do
      stream.push(2)
    rescue Channel::ClosedError
      done.send(nil)
    end
    Fiber.yield
    stream.cancel
    select
    when done.receive
    when timeout(1.second)
      fail "cancel left the typed producer blocked"
    end
    stream.finish(GRPC::Status.internal("closed queue"))
    stream.status.code.should eq(GRPC::StatusCode::CANCELLED)
  end
end
