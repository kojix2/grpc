require "../spec_helper"

describe GRPC::Health::Service do
  describe "#dispatch Check" do
    it "returns SERVING for empty service by default" do
      service = GRPC::Health::Service.new
      ctx = GRPC::ServerContext.new("peer")
      request = Grpc::Health::V1::HealthCheckRequest.new

      body, status = service.dispatch("Check", request.encode, ctx)
      status.should eq(GRPC::Status.ok)
      response = Grpc::Health::V1::HealthCheckResponse.decode(body)
      GRPC::Health.serving_status_from_wire(response.status).should eq(Grpc::Health::V1::HealthCheckResponse::ServingStatus::SERVING)
    end

    it "returns configured status for named service" do
      service = GRPC::Health::Service.new
      service.reporter.set_status("my.service", Grpc::Health::V1::HealthCheckResponse::ServingStatus::NOT_SERVING)
      ctx = GRPC::ServerContext.new("peer")
      req = Grpc::Health::V1::HealthCheckRequest.new
      req.service = "my.service"

      body, status = service.dispatch("Check", req.encode, ctx)
      status.should eq(GRPC::Status.ok)
      response = Grpc::Health::V1::HealthCheckResponse.decode(body)
      GRPC::Health.serving_status_from_wire(response.status).should eq(Grpc::Health::V1::HealthCheckResponse::ServingStatus::NOT_SERVING)
    end

    it "returns NOT_FOUND when named service has no status" do
      service = GRPC::Health::Service.new
      ctx = GRPC::ServerContext.new("peer")
      req = Grpc::Health::V1::HealthCheckRequest.new
      req.service = "my.service"

      body, status = service.dispatch("Check", req.encode, ctx)
      body.should be_empty
      status.should eq(GRPC::Status.not_found("unknown service my.service"))
    end
  end

  describe "#dispatch List" do
    it "lists all currently known health statuses" do
      service = GRPC::Health::Service.new
      service.reporter.set_status("my.service", Grpc::Health::V1::HealthCheckResponse::ServingStatus::NOT_SERVING)
      ctx = GRPC::ServerContext.new("peer")
      request = Grpc::Health::V1::HealthListRequest.new

      body, status = service.dispatch("List", request.encode, ctx)

      status.should eq(GRPC::Status.ok)
      response = Grpc::Health::V1::HealthListResponse.decode(body)
      statuses = response.statuses.transform_values do |value|
        GRPC::Health.serving_status_from_wire(value.status)
      end
      statuses.should eq({
        ""           => Grpc::Health::V1::HealthCheckResponse::ServingStatus::SERVING,
        "my.service" => Grpc::Health::V1::HealthCheckResponse::ServingStatus::NOT_SERVING,
      })
    end
  end

  describe "#dispatch_server_stream Watch" do
    it "treats Watch as server-streaming" do
      service = GRPC::Health::Service.new
      service.server_streaming?("Watch").should be_true
      service.server_streaming?("Check").should be_false
    end

    it "Watch sends initial unknown status, then updates, until cancelled" do
      service = GRPC::Health::Service.new
      ctx = GRPC::ServerContext.new("peer")
      req = Grpc::Health::V1::HealthCheckRequest.new
      req.service = "my.service"
      sent = ::Channel(Bytes).new(2)
      writer = GRPC::RawResponseStream.new(->(bytes : Bytes) { sent.send(bytes); nil })
      done = ::Channel(GRPC::Status).new(1)

      spawn do
        done.send(service.dispatch_server_stream("Watch", req.encode, ctx, writer))
      end

      first_frame = sent.receive
      body, consumed = GRPC::Codec.decode(first_frame)
      consumed.should eq(first_frame.size)
      response = Grpc::Health::V1::HealthCheckResponse.decode(body)
      GRPC::Health.serving_status_from_wire(response.status).should eq(Grpc::Health::V1::HealthCheckResponse::ServingStatus::SERVICE_UNKNOWN)

      service.reporter.set_status("my.service", Grpc::Health::V1::HealthCheckResponse::ServingStatus::NOT_SERVING)

      second_frame = sent.receive
      body, consumed = GRPC::Codec.decode(second_frame)
      consumed.should eq(second_frame.size)
      response = Grpc::Health::V1::HealthCheckResponse.decode(body)
      GRPC::Health.serving_status_from_wire(response.status).should eq(Grpc::Health::V1::HealthCheckResponse::ServingStatus::NOT_SERVING)

      ctx.cancel
      done.receive.code.should eq(GRPC::StatusCode::CANCELLED)
    end
  end
end

describe GRPC::Health::Registry do
  it "keeps the latest state for a slow watcher without blocking other watchers" do
    registry = GRPC::Health::Registry.new
    slow, _ = registry.subscribe("test")
    fast, _ = registry.subscribe("test")
    completed = Channel(Nil).new(1)
    spawn do
      20.times do |i|
        status = i.even? ? Grpc::Health::V1::HealthCheckResponse::ServingStatus::SERVING : Grpc::Health::V1::HealthCheckResponse::ServingStatus::NOT_SERVING
        registry.set_status("test", status)
        fast.receive.should eq(status)
      end
      completed.send(nil)
    end
    select
    when completed.receive
    when timeout(1.second)
      fail "slow watcher blocked health updates"
    end
    slow.receive.should eq(Grpc::Health::V1::HealthCheckResponse::ServingStatus::NOT_SERVING)
  ensure
    registry.try &.unsubscribe("test", slow) if slow
    registry.try &.unsubscribe("test", fast) if fast
  end

  it "closes subscriptions on unsubscribe" do
    registry = GRPC::Health::Registry.new
    subscription, _ = registry.subscribe("test")
    registry.unsubscribe("test", subscription)
    subscription.closed?.should be_true
  end
end
