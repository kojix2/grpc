require "../spec_helper"

describe GRPC::Transport::PendingCall do
  describe "metadata" do
    it "has no trailers before the first trailer block" do
      call = GRPC::Transport::PendingCall.new
      call.begin_header_block
      call.add_header(":status", "200")
      call.add_header("x-initial", "one")

      call.grpc_trailers.empty?.should be_true
    end

    it "separates initial headers from trailing metadata" do
      call = GRPC::Transport::PendingCall.new
      call.begin_header_block
      call.add_header(":status", "200")
      call.add_header("x-initial", "one")
      call.begin_header_block
      call.add_header("grpc-status", "0")
      call.add_header("x-trailer", "done")

      call.grpc_headers.get("x-initial").should eq("one")
      call.grpc_headers.get("x-trailer").should be_nil
      call.grpc_trailers.get("x-trailer").should eq("done")
    end
  end

  describe "status" do
    it "changes status from UNKNOWN to OK when trailers arrive" do
      call = GRPC::Transport::PendingCall.new

      call.grpc_status.code.should eq(GRPC::StatusCode::UNKNOWN)

      call.begin_header_block
      call.add_header(":status", "200")
      call.grpc_status.code.should eq(GRPC::StatusCode::UNKNOWN)

      call.begin_header_block
      call.add_header("grpc-status", "0")
      call.grpc_status.code.should eq(GRPC::StatusCode::OK)
    end

    it "decodes grpc-status-details-bin from trailers" do
      call = GRPC::Transport::PendingCall.new
      call.trailers.add("grpc-status", GRPC::StatusCode::INVALID_ARGUMENT.value.to_s)
      call.trailers.add("grpc-message", "bad%20request")
      call.trailers.add_bin("grpc-status-details-bin", Bytes[0x0A, 0x01, 0x7F])

      status = call.grpc_status
      status.code.should eq(GRPC::StatusCode::INVALID_ARGUMENT)
      status.message.should eq("bad request")
      status.details.should eq(Bytes[0x0A, 0x01, 0x7F])
    end

    it "treats missing grpc-status as UNKNOWN" do
      call = GRPC::Transport::PendingCall.new

      status = call.grpc_status
      status.code.should eq(GRPC::StatusCode::UNKNOWN)
      status.message.should contain("missing grpc-status")
    end

    it "prefers transport error override over grpc-status when trailers are present" do
      call = GRPC::Transport::PendingCall.new
      call.trailers.add("grpc-status", "0")
      call.transport_error = GRPC::Status.unknown("transport close")

      call.grpc_status.code.should eq(GRPC::StatusCode::UNKNOWN)
      call.grpc_status.message.should eq("transport close")
    end

    it "keeps invalid response metadata as the final status even with grpc-status" do
      call = GRPC::Transport::PendingCall.new
      call.begin_header_block
      call.add_header("trace-bin", "!!!")
      call.begin_header_block
      call.add_header("grpc-status", "0")

      status = call.grpc_status
      status.code.should eq(GRPC::StatusCode::INTERNAL)
      status.message.should contain("invalid wire metadata")
    end
  end

  describe "completion" do
    it "completes only once" do
      call = GRPC::Transport::PendingCall.new

      call.complete
      call.complete

      call.wait
    end

    it "ignores transport errors reported after completion" do
      call = GRPC::Transport::PendingCall.new
      call.trailers.add("grpc-status", "0")

      call.complete
      call.transport_error = GRPC::Status.unknown("late close")

      call.grpc_status.code.should eq(GRPC::StatusCode::OK)
    end
  end
end
