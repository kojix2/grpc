require "../spec_helper"

describe GRPC::Server do
  it "returns a health reporter" do
    server = GRPC::Server.new

    reporter = server.enable_health_checking
    reporter.should be_a(GRPC::Health::Reporter)
  end

  it "reuses existing health reporter on repeated calls" do
    server = GRPC::Server.new

    first = server.enable_health_checking
    second = server.enable_health_checking(default_status: Grpc::Health::V1::HealthCheckResponse::ServingStatus::NOT_SERVING)

    second.should be(first)
  end

  it "pushes NOT_SERVING to active health watchers on stop" do
    server = GRPC::Server.new
    reporter = server.enable_health_checking
    reporter.set_status("my.service", Grpc::Health::V1::HealthCheckResponse::ServingStatus::SERVING)
    port_probe = TCPServer.new("127.0.0.1", 0)
    port = port_probe.local_address.as(Socket::IPAddress).port
    port_probe.close
    server.bind("127.0.0.1:#{port}")
    server.start

    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    client = Grpc::Health::V1::Health::Client.new(channel)
    request = Grpc::Health::V1::HealthCheckRequest.new
    request.service = "my.service"
    stream = client.watch(request)

    statuses = ::Channel(Grpc::Health::V1::HealthCheckResponse::ServingStatus).new(2)
    done = ::Channel(Nil).new(1)

    spawn do
      stream.each do |message|
        statuses.send(GRPC::Health.serving_status_from_wire(message.status))
      end
    ensure
      done.send(nil)
    end

    statuses.receive.should eq(Grpc::Health::V1::HealthCheckResponse::ServingStatus::SERVING)

    server.stop
    statuses.receive.should eq(Grpc::Health::V1::HealthCheckResponse::ServingStatus::NOT_SERVING)
    done.receive
  ensure
    stream.try &.cancel
    channel.try &.close
  end
end
