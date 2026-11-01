require "../spec_helper"

describe GRPC::Transport::StreamHeaderState do
  it "routes first headers block to headers and next block to trailers" do
    state = GRPC::Transport::StreamHeaderState.new

    state.begin_header_block
    state.add_header(":status", "200")
    state.add_header("content-type", "application/grpc")

    state.begin_header_block
    state.add_header("grpc-status", "0")

    state.headers.get(":status").should eq("200")
    state.trailers.get("grpc-status").should eq("0")
  end
end

describe GRPC::Transport::StreamTerminalState do
  it "allows finish/cancel transitions only once" do
    lifecycle = GRPC::Transport::StreamTerminalState.new

    lifecycle.mark_finished.should be_true
    lifecycle.mark_finished.should be_false
    lifecycle.mark_cancelled.should be_true
    lifecycle.mark_cancelled.should be_false
  end
end
