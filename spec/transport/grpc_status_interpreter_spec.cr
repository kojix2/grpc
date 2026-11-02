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
  {400 => GRPC::StatusCode::INTERNAL,
   401 => GRPC::StatusCode::UNAUTHENTICATED,
   403 => GRPC::StatusCode::PERMISSION_DENIED,
   404 => GRPC::StatusCode::UNIMPLEMENTED,
   429 => GRPC::StatusCode::UNAVAILABLE,
   502 => GRPC::StatusCode::UNAVAILABLE,
   503 => GRPC::StatusCode::UNAVAILABLE,
   504 => GRPC::StatusCode::UNAVAILABLE,
   200 => GRPC::StatusCode::UNKNOWN}.each do |http, expected|
    it "maps HTTP #{http} when grpc-status is absent" do
      headers = GRPC::Metadata.new({":status" => http.to_s})
      GRPC::Transport::GrpcStatusInterpreter.grpc_status(headers, GRPC::Metadata.new, nil).code.should eq(expected)
    end
  end

  it "prefers a valid gRPC status over the HTTP fallback" do
    headers = GRPC::Metadata.new({":status" => "503", "grpc-status" => "7"})
    GRPC::Transport::GrpcStatusInterpreter.grpc_status(headers, GRPC::Metadata.new, nil).code.should eq(GRPC::StatusCode::PERMISSION_DENIED)
  end
end
