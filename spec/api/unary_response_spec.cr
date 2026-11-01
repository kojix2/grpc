require "../spec_helper"

describe GRPC::UnaryResponse do
  describe "non-OK status" do
    it "raises with the original non-OK status" do
      trailers = GRPC::Metadata.new
      trailers.add("x-extra", "value")
      response = GRPC::UnaryResponse(String).new(nil, GRPC::Metadata.new, trailers, GRPC::Status.internal("boom"))

      ex = expect_raises(GRPC::StatusError) { response.ok! }
      ex.status.code.should eq(GRPC::StatusCode::INTERNAL)
      ex.status.message.should eq("boom")
    end

    it "preserves trailing metadata when status is non-OK" do
      trailers_non_ok = GRPC::Metadata.new
      trailers_non_ok.add("x-extra", "non-ok")
      non_ok = GRPC::UnaryResponse(String).new(nil, GRPC::Metadata.new, trailers_non_ok, GRPC::Status.internal("boom"))

      ex_non_ok = expect_raises(GRPC::StatusError) { non_ok.ok! }
      ex_non_ok.trailers.get("x-extra").should eq("non-ok")
    end
  end

  describe "missing message" do
    it "raises INTERNAL when status is OK but message is missing" do
      response = GRPC::UnaryResponse(String).new(nil, GRPC::Metadata.new, GRPC::Metadata.new, GRPC::Status.ok)

      ex = expect_raises(GRPC::StatusError) { response.ok! }
      ex.status.code.should eq(GRPC::StatusCode::INTERNAL)
      ex.status.message.should eq("unary response message missing")
    end

    it "preserves trailing metadata when an OK response has no message" do
      trailers_missing = GRPC::Metadata.new
      trailers_missing.add("x-extra", "missing")
      missing_message = GRPC::UnaryResponse(String).new(nil, GRPC::Metadata.new, trailers_missing, GRPC::Status.ok)

      ex_missing = expect_raises(GRPC::StatusError) { missing_message.ok! }
      ex_missing.trailers.get("x-extra").should eq("missing")
    end
  end
end
