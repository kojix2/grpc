require "../spec_helper"

describe GRPC::RawServerStream do
  describe "metadata" do
    it "returns empty headers and trailers in initial state" do
      ch = ::Channel(Bytes?).new
      stream = GRPC::RawServerStream.new(ch, -> { GRPC::Status.ok })
      stream.headers.empty?.should be_true
      stream.trailers.empty?.should be_true
    end

    it "exposes initial headers separately from trailers" do
      headers = GRPC::Metadata.new
      headers.add("x-initial", "one")
      trailers = GRPC::Metadata.new
      trailers.add("x-trailer", "done")
      messages = ::Channel(Bytes?).new(1)
      messages.close

      stream = GRPC::RawServerStream.new(messages, -> { GRPC::Status.ok }, -> { trailers }).with_headers(-> { headers })

      stream.headers.get("x-initial").should eq("one")
      stream.trailers.get("x-trailer").should eq("done")
    end
  end

  describe "completion and cancellation" do
    it "runs finish hooks once after iteration completes" do
      ch = ::Channel(Bytes?).new(2)
      ch.send(Bytes[1_u8])
      ch.close

      finishes = 0
      stream = GRPC::RawServerStream.new(ch, -> { GRPC::Status.ok }).with_on_finish(-> { finishes += 1; nil })

      received = [] of Bytes
      stream.each { |msg| received << msg }

      received.should eq([Bytes[1_u8]])
      finishes.should eq(1)
    end

    it "invokes cancel once and runs finish hooks once across repeated cancel calls" do
      ch = ::Channel(Bytes?).new(1)
      cancels = 0
      finishes = 0
      stream = GRPC::RawServerStream.new(ch, -> { GRPC::Status.ok }, -> { GRPC::Metadata.new }, -> { cancels += 1; nil }).with_on_finish(-> { finishes += 1; nil })

      stream.cancel
      stream.cancel

      cancels.should eq(1)
      finishes.should eq(1)
    end
  end
end

describe GRPC::RawClientCall do
  describe "metadata" do
    it "returns empty headers and trailers in initial state" do
      call = GRPC::RawClientCall.new(
        ->(_b : Bytes) { },
        -> { Bytes.empty },
        -> { GRPC::Metadata.new },
        -> { GRPC::Status.ok },
        -> { GRPC::Metadata.new },
        -> { }
      )
      call.headers.empty?.should be_true
      call.trailers.empty?.should be_true
    end
  end

  describe "completion and cancellation" do
    it "invokes cancel once and runs finish hooks once even if cancel follows close_and_recv" do
      cancels = 0
      finishes = 0
      call = GRPC::RawClientCall.new(
        ->(_b : Bytes) { },
        -> { Bytes[7_u8] },
        -> { GRPC::Metadata.new },
        -> { GRPC::Status.ok },
        -> { GRPC::Metadata.new },
        -> { cancels += 1; nil }
      ).with_on_finish(-> { finishes += 1; nil })

      call.close_and_recv.should eq(Bytes[7_u8])
      call.cancel
      call.cancel

      cancels.should eq(1)
      finishes.should eq(1)
    end
  end
end

describe GRPC::RawBidiCall do
  it "exposes transport completion independently of its iteration finish hook" do
    messages = Channel(Bytes?).new(1)
    messages.send(Bytes[7_u8])
    final = nil.as(GRPC::Status?)
    finishes = 0
    call = GRPC::RawBidiCall.new(
      ->(_bytes : Bytes) { nil }, -> { nil }, messages,
      -> { GRPC::Metadata.new }, -> { GRPC::Status.ok },
      -> { GRPC::Metadata.new }, -> { nil },
      final_status_proc: -> { final }
    ).with_on_finish(-> { finishes += 1; nil })

    call.final_status.should be_nil
    final = GRPC::Status.ok
    call.final_status.should eq(GRPC::Status.ok)
    finishes.should eq(0)
    messages.close
    call.to_a.should eq([Bytes[7_u8]])
    finishes.should eq(1)
  end

  describe "metadata" do
    it "returns empty headers and trailers in initial state" do
      ch = ::Channel(Bytes?).new
      call = GRPC::RawBidiCall.new(
        ->(_b : Bytes) { },
        -> { },
        ch,
        -> { GRPC::Metadata.new },
        -> { GRPC::Status.ok },
        -> { GRPC::Metadata.new },
        -> { }
      )
      call.headers.empty?.should be_true
      call.trailers.empty?.should be_true
    end
  end

  describe "completion and cancellation" do
    it "invokes cancel once and runs finish hooks once even if cancel follows iteration" do
      ch = ::Channel(Bytes?).new(2)
      ch.send(Bytes[9_u8])
      ch.close

      cancels = 0
      finishes = 0
      call = GRPC::RawBidiCall.new(
        ->(_b : Bytes) { },
        -> { },
        ch,
        -> { GRPC::Metadata.new },
        -> { GRPC::Status.ok },
        -> { GRPC::Metadata.new },
        -> { cancels += 1; nil }
      ).with_on_finish(-> { finishes += 1; nil })

      received = [] of Bytes
      call.each { |msg| received << msg }
      call.cancel
      call.cancel

      received.should eq([Bytes[9_u8]])
      cancels.should eq(1)
      finishes.should eq(1)
    end
  end
end
