module GRPC
  # Endpoint describes where a client channel connects.
  # It encapsulates host/port/TLS derived from an address string.
  struct Endpoint
    getter host : String
    getter port : Int32
    getter? tls : Bool

    def initialize(@host : String, @port : Int32, @tls : Bool = false)
    end

    # Parse common endpoint forms:
    # - host:port
    # - http://host:port
    # - https://host:port
    # - host (defaults: 50051 for plain, 443 for TLS)
    def self.parse(address : String) : Endpoint
      addr, use_tls = split_scheme(address)
      host, port = parse_host_and_port(addr.split('/').first, use_tls, address)
      Endpoint.new(host, port, use_tls)
    end

    private def self.split_scheme(address : String) : {String, Bool}
      if address.starts_with?("https://")
        {address[8..], true}
      elsif address.starts_with?("http://")
        {address[7..], false}
      else
        {address, false}
      end
    end

    private def self.parse_host_and_port(addr : String, use_tls : Bool, original : String) : {String, Int32}
      return parse_ipv6_host(addr, use_tls, original) if addr.starts_with?("[")
      return parse_host_with_port(addr) if addr.includes?(":")
      parse_host_without_port(addr, use_tls)
    end

    private def self.parse_ipv6_host(addr : String, use_tls : Bool, original : String) : {String, Int32}
      closing = addr.index(']')
      raise ArgumentError.new("invalid IPv6 endpoint: #{original}") unless closing

      host = addr[0..closing]
      suffix = addr[closing + 1..]
      {host, parse_ipv6_port_suffix(suffix, use_tls, original)}
    end

    private def self.parse_ipv6_port_suffix(suffix : String, use_tls : Bool, original : String) : Int32
      return default_port(use_tls) if suffix.empty? || suffix == ":"
      raise ArgumentError.new("invalid endpoint suffix: #{original}") unless suffix.starts_with?(":")
      suffix[1..].to_i
    end

    private def self.parse_host_with_port(addr : String) : {String, Int32}
      idx = addr.rindex(':') || 0
      host = addr[0, idx]
      host = "localhost" if host.empty?
      {host, addr[idx + 1..].to_i}
    end

    private def self.parse_host_without_port(addr : String, use_tls : Bool) : {String, Int32}
      host = addr.empty? ? "localhost" : addr
      {host, default_port(use_tls)}
    end

    private def self.default_port(use_tls : Bool) : Int32
      use_tls ? 443 : 50051
    end

    def to_address : String
      scheme = tls? ? "https" : "http"
      "#{scheme}://#{host}:#{port}"
    end
  end

  # KeepaliveParams controls transport-level keepalive behaviour.
  class KeepaliveParams
    property interval : Time::Span
    property timeout : Time::Span
    property? permit_without_calls : Bool

    def initialize(
      @interval : Time::Span = 30.seconds,
      @timeout : Time::Span = 10.seconds,
      @permit_without_calls : Bool = false,
    )
    end
  end

  # BackoffConfig defines reconnect delay strategy.
  class BackoffConfig
    property base_delay : Time::Span
    property multiplier : Float64
    property jitter : Float64
    property max_delay : Time::Span

    def initialize(
      @base_delay : Time::Span = 1.second,
      @multiplier : Float64 = 1.6,
      @jitter : Float64 = 0.2,
      @max_delay : Time::Span = 120.seconds,
    )
    end
  end

  # RateLimitConfig limits request starts to *limit* per *period*.
  class RateLimitConfig
    property limit : UInt64
    property period : Time::Span

    def initialize(@limit : UInt64, @period : Time::Span)
    end
  end

  # EndpointConfig gathers channel-level transport and lifecycle settings.
  # This is the primary configuration entry point for future connection manager work.
  class EndpointConfig
    property connect_timeout : Time::Span?
    property tcp_keepalive : Time::Span?
    property keepalive : KeepaliveParams?
    property concurrency_limit : Int32?
    property rate_limit : RateLimitConfig?
    property backoff : BackoffConfig

    def initialize(
      @connect_timeout : Time::Span? = nil,
      @tcp_keepalive : Time::Span? = nil,
      @keepalive : KeepaliveParams? = nil,
      @concurrency_limit : Int32? = nil,
      @rate_limit : RateLimitConfig? = nil,
      @backoff : BackoffConfig = BackoffConfig.new,
    )
    end
  end
end
