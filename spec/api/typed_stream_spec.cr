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
