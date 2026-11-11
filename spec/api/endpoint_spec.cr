require "../spec_helper"

describe GRPC::Endpoint do
  it "parses plain host and port" do
    endpoint = GRPC::Endpoint.parse("example.com:1234")
    endpoint.host.should eq("example.com")
    endpoint.port.should eq(1234)
    endpoint.tls?.should be_false
  end

  it "parses scheme-specific default ports" do
    plain = GRPC::Endpoint.parse("http://example.com")
    plain.host.should eq("example.com")
    plain.port.should eq(50051)
    plain.tls?.should be_false

    tls = GRPC::Endpoint.parse("https://example.com")
    tls.host.should eq("example.com")
    tls.port.should eq(443)
    tls.tls?.should be_true
  end

  it "strips trailing path components" do
    endpoint = GRPC::Endpoint.parse("https://example.com:8443/foo/bar")
    endpoint.host.should eq("example.com")
    endpoint.port.should eq(8443)
    endpoint.tls?.should be_true
  end

  it "parses bracketed IPv6 endpoints with and without explicit port" do
    endpoint = GRPC::Endpoint.parse("http://[::1]:8080")
    endpoint.host.should eq("[::1]")
    endpoint.port.should eq(8080)
    endpoint.tls?.should be_false

    tls_endpoint = GRPC::Endpoint.parse("https://[::1]")
    tls_endpoint.host.should eq("[::1]")
    tls_endpoint.port.should eq(443)
    tls_endpoint.tls?.should be_true
  end

  it "renders addresses with the correct scheme" do
    GRPC::Endpoint.new("example.com", 50051).to_address.should eq("http://example.com:50051")
    GRPC::Endpoint.new("example.com", 443, true).to_address.should eq("https://example.com:443")
    GRPC::Endpoint.new("::1", 443, true).to_address.should eq("https://[::1]:443")
    GRPC::Endpoint.new("[::1]", 443, true).to_address.should eq("https://[::1]:443")
    GRPC::Endpoint.socket_host("[::1]").should eq("::1")
  end
end
