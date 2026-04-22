require "../spec_helper"
require "./shared"

describe "grpcurl e2e tls" do
  it "invokes unary over TLS with the configured CA" do
    next unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    configure_e2e_tls_server(server)
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      args = grpcurl_tls_call_args(
        "localhost",
        port,
        "e2e.Probe/UnaryEcho",
        e2e_tls_grpcurl_flags + ["-d", "{\"message\":\"hello\"}"],
      )
      status, out, err = run_grpcurl(args)
      raise "grpcurl tls call failed: #{err}\nstdout: #{out}" unless status.success?
      out.should contain("echo:hello")
    ensure
      server.stop
    end
  end

  it "fails TLS without the configured CA" do
    next unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    configure_e2e_tls_server(server)
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      args = grpcurl_tls_call_args(
        "localhost",
        port,
        "e2e.Probe/UnaryEcho",
        ["-d", "{\"message\":\"hello\"}"],
      )
      status, out, err = run_grpcurl(args)
      raise "expected tls verification failure" if status.success?
      detail = "#{out}\n#{err}".downcase
      detail.includes?("certificate") || detail.includes?("unknown authority") || detail.includes?("signed by unknown").should be_true
    ensure
      server.stop
    end
  end

  it "fails TLS on hostname mismatch" do
    next unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    configure_e2e_tls_server(server)
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      args = grpcurl_tls_call_args(
        "127.0.0.1",
        port,
        "e2e.Probe/UnaryEcho",
        e2e_tls_grpcurl_flags + ["-d", "{\"message\":\"hello\"}"],
      )
      status, out, err = run_grpcurl(args)
      raise "expected hostname verification failure" if status.success?
      detail = "#{out}\n#{err}".downcase
      detail.includes?("hostname") || detail.includes?("not 127.0.0.1") || detail.includes?("doesn't contain any ip sans").should be_true
    ensure
      server.stop
    end
  end

  it "invokes unary over mTLS with a client certificate" do
    next unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    configure_e2e_tls_server(server, require_client_cert: true)
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      args = grpcurl_tls_call_args(
        "localhost",
        port,
        "e2e.Probe/UnaryEcho",
        e2e_tls_grpcurl_flags(include_client_cert: true) + ["-d", "{\"message\":\"hello\"}"],
      )
      status, out, err = run_grpcurl(args)
      raise "grpcurl mtls call failed: #{err}\nstdout: #{out}" unless status.success?
      out.should contain("echo:hello")
    ensure
      server.stop
    end
  end

  it "fails mTLS without a client certificate" do
    next unless grpcurl_available?

    port = find_free_port
    server = GRPC::Server.new
    configure_e2e_tls_server(server, require_client_cert: true)
    server.handle E2EProbeService.new
    server.bind("127.0.0.1:#{port}")
    server.start

    begin
      wait_for_server(port)
      args = grpcurl_tls_call_args(
        "localhost",
        port,
        "e2e.Probe/UnaryEcho",
        e2e_tls_grpcurl_flags + ["-max-time", "1", "-d", "{\"message\":\"hello\"}"],
      )
      status, out, err = run_grpcurl(args)
      raise "expected mtls client certificate failure" if status.success?
      detail = "#{out}\n#{err}".downcase
      detail.includes?("failed to dial") || detail.includes?("deadline exceeded") || detail.includes?("context deadline exceeded").should be_true
    ensure
      server.stop
    end
  end
end
