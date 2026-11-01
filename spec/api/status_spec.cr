require "../spec_helper"

describe GRPC::StatusCode do
  it "has standard gRPC status codes" do
    GRPC::StatusCode::OK.value.should eq(0)
    GRPC::StatusCode::CANCELLED.value.should eq(1)
    GRPC::StatusCode::UNIMPLEMENTED.value.should eq(12)
  end
end

describe GRPC::Status do
  it "creates OK status" do
    s = GRPC::Status.ok
    s.ok?.should be_true
    s.code.should eq(GRPC::StatusCode::OK)
  end

  it "creates error status" do
    s = GRPC::Status.new(GRPC::StatusCode::NOT_FOUND, "resource not found")
    s.ok?.should be_false
    s.message.should eq("resource not found")
  end

  it "can carry optional status details bytes" do
    details = Bytes[0x01, 0x02, 0x03]
    s = GRPC::Status.new(GRPC::StatusCode::INTERNAL, "boom", details)

    s.details.should eq(details)
  end
end

describe GRPC::StatusError do
  it "exposes code and message" do
    ex = GRPC::StatusError.new(GRPC::StatusCode::NOT_FOUND, "missing")
    ex.code.should eq(GRPC::StatusCode::NOT_FOUND)
    ex.message.should eq("missing")
  end

  it "can be constructed from a Status" do
    status = GRPC::Status.new(GRPC::StatusCode::INTERNAL, "boom")
    ex = GRPC::StatusError.new(status)
    ex.status.should eq(status)
  end

  it "retains trailers when provided" do
    trailers = GRPC::Metadata.new
    trailers.add("x-extra", "value")

    ex = GRPC::StatusError.new(GRPC::Status.internal("boom"), trailers)

    ex.trailers.get("x-extra").should eq("value")
  end
end
