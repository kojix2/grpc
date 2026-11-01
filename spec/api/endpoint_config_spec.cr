require "../spec_helper"

describe GRPC::EndpointConfig do
  describe "numeric validation" do
    it "rejects nonpositive connect_timeout before opening a connection" do
      expect_raises(ArgumentError, /connect_timeout/) do
        GRPC::Channel.new("127.0.0.1:12345", endpoint_config: GRPC::EndpointConfig.new(connect_timeout: 0.seconds))
      end
    end

    it "rejects negative tcp_keepalive before opening a connection" do
      expect_raises(ArgumentError, /tcp_keepalive/) do
        GRPC::Channel.new("127.0.0.1:12345", endpoint_config: GRPC::EndpointConfig.new(tcp_keepalive: -1.second))
      end
    end

    it "rejects nonpositive keepalive interval before opening a connection" do
      expect_raises(ArgumentError, /keepalive.interval/) do
        GRPC::Channel.new(
          "127.0.0.1:12345",
          endpoint_config: GRPC::EndpointConfig.new(keepalive: GRPC::KeepaliveParams.new(interval: 0.seconds))
        )
      end
    end

    it "rejects nonpositive keepalive timeout before opening a connection" do
      expect_raises(ArgumentError, /keepalive.timeout/) do
        GRPC::Channel.new(
          "127.0.0.1:12345",
          endpoint_config: GRPC::EndpointConfig.new(keepalive: GRPC::KeepaliveParams.new(timeout: 0.seconds))
        )
      end
    end

    it "rejects nonpositive concurrency_limit before opening a connection" do
      expect_raises(ArgumentError, /concurrency_limit/) do
        GRPC::Channel.new("127.0.0.1:12345", endpoint_config: GRPC::EndpointConfig.new(concurrency_limit: 0))
      end
    end

    it "rejects nonpositive rate_limit count before opening a connection" do
      expect_raises(ArgumentError, /rate_limit.limit/) do
        GRPC::Channel.new(
          "127.0.0.1:12345",
          endpoint_config: GRPC::EndpointConfig.new(rate_limit: GRPC::RateLimitConfig.new(0_u64, 1.second))
        )
      end
    end

    it "rejects nonpositive rate_limit period before opening a connection" do
      expect_raises(ArgumentError, /rate_limit.period/) do
        GRPC::Channel.new(
          "127.0.0.1:12345",
          endpoint_config: GRPC::EndpointConfig.new(rate_limit: GRPC::RateLimitConfig.new(1_u64, 0.seconds))
        )
      end
    end
  end
end
