require "../spec_helper"

describe GRPC::Transport::GrpcStatusInterpreter do
  it "prefers trailers and decodes grpc-message" do
    headers = GRPC::Metadata.new
    trailers = GRPC::Metadata.new
    trailers.add("grpc-status", "3")
    trailers.add("grpc-message", "invalid%20input")

    status = GRPC::Transport::GrpcStatusInterpreter.grpc_status(headers, trailers, nil)
    status.code.should eq(GRPC::StatusCode::INVALID_ARGUMENT)
    status.message.should eq("invalid input")
  end

  it "treats non-numeric grpc-status as UNKNOWN" do
    headers = GRPC::Metadata.new
    trailers = GRPC::Metadata.new
    trailers.add("grpc-status", "abc")

    status = GRPC::Transport::GrpcStatusInterpreter.grpc_status(headers, trailers, nil)
    status.code.should eq(GRPC::StatusCode::UNKNOWN)
    status.message.should eq("invalid grpc-status: abc")
  end

  it "treats out-of-range grpc-status as UNKNOWN" do
    headers = GRPC::Metadata.new
    trailers = GRPC::Metadata.new
    trailers.add("grpc-status", "999")

    status = GRPC::Transport::GrpcStatusInterpreter.grpc_status(headers, trailers, nil)
    status.code.should eq(GRPC::StatusCode::UNKNOWN)
    status.message.should eq("invalid grpc-status: 999")
  end

  it "falls back to headers grpc-status when trailers are missing" do
    headers = GRPC::Metadata.new
    trailers = GRPC::Metadata.new
    headers.add("grpc-status", "3")
    headers.add("grpc-message", "header%20only")

    status = GRPC::Transport::GrpcStatusInterpreter.grpc_status(headers, trailers, nil)
    status.code.should eq(GRPC::StatusCode::INVALID_ARGUMENT)
    status.message.should eq("header only")
  end

  it "uses override when grpc-status is missing" do
    headers = GRPC::Metadata.new
    trailers = GRPC::Metadata.new
    override = GRPC::Status.internal("transport failure")

    status = GRPC::Transport::GrpcStatusInterpreter.grpc_status(headers, trailers, override)
    status.should eq(override)
  end

  it "prefers override over grpc-status when transport failed" do
    headers = GRPC::Metadata.new
    trailers = GRPC::Metadata.new
    trailers.add("grpc-status", "0")
    override = GRPC::Status.internal("transport failure")

    status = GRPC::Transport::GrpcStatusInterpreter.grpc_status(headers, trailers, override)
    status.should eq(override)
  end
end
