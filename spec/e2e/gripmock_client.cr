require "http/client"
require "json"
require "socket"
require "./proto_helpers"

MISSING_GRIPMOCK_MSG = "gripmock is not available; failing gripmock client e2e tests"
GRIPMOCK_ADMIN_MSG   = "gripmock admin API is not available; failing gripmock client e2e tests"

GRIPMOCK_HOST       = ENV["GRIPMOCK_HOST"]? || "127.0.0.1"
GRIPMOCK_GRPC_PORT  = (ENV["GRIPMOCK_GRPC_PORT"]? || "4770").to_i
GRIPMOCK_ADMIN_PORT = (ENV["GRIPMOCK_ADMIN_PORT"]? || "4771").to_i

def tcp_port_open?(host : String, port : Int32) : Bool
  socket = TCPSocket.new(host, port)
  socket.close
  true
rescue
  false
end

def gripmock_available? : Bool
  tcp_port_open?(GRIPMOCK_HOST, GRIPMOCK_GRPC_PORT) &&
    tcp_port_open?(GRIPMOCK_HOST, GRIPMOCK_ADMIN_PORT)
end

def gripmock_target : String
  "#{GRIPMOCK_HOST}:#{GRIPMOCK_GRPC_PORT}"
end

def gripmock_admin_base : String
  "http://#{GRIPMOCK_HOST}:#{GRIPMOCK_ADMIN_PORT}"
end

def admin_get(path : String) : Int32?
  response = HTTP::Client.get("#{gripmock_admin_base}#{path}")
  response.status_code
rescue
  nil
end

def admin_post(path : String, payload : String) : Int32?
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  response = HTTP::Client.post("#{gripmock_admin_base}#{path}", headers: headers, body: payload)
  response.status_code
rescue
  nil
end

def gripmock_try_post(paths : Array(String), payload : String) : Bool
  paths.any? do |path|
    code = admin_post(path, payload)
    !code.nil? && code >= 200 && code < 300
  end
end

def gripmock_clear_stubs : Bool
  code = admin_get("/clear")
  !code.nil? && code >= 200 && code < 300
end

def gripmock_add_stub(stub_payload : String) : Bool
  gripmock_try_post(["/add"], stub_payload)
end

def gripmock_admin_available? : Bool
  gripmock_clear_stubs
end

def require_gripmock! : Nil
  raise MISSING_GRIPMOCK_MSG unless gripmock_available?
end

def require_gripmock_admin! : Nil
  raise GRIPMOCK_ADMIN_MSG unless gripmock_admin_available?
end

def require_stub_added!(payload : String) : Nil
  raise GRIPMOCK_ADMIN_MSG unless gripmock_add_stub(payload)
end

def build_stub(service : String, method : String, output_message : String,
               input_message : String? = nil, metadata : Hash(String, String)? = nil,
               code : Int32? = nil, error_message : String? = nil, delay_ms : Int32? = nil) : String
  output = JSON.build do |json|
    json.object do
      json.field "data" do
        json.object do
          json.field "message", output_message
        end
      end
      if value = code
        json.field "code", value
      end
      if value = error_message
        json.field "error", value
      end
      if value = delay_ms
        json.field "delay", value
      end
    end
  end

  JSON.build do |json|
    json.object do
      json.field "service", service
      json.field "method", method
      json.field "input" do
        json.object do
          unless input_message.nil?
            json.field "equals" do
              json.object do
                json.field "message", input_message
              end
            end
          end
          unless metadata.nil?
            json.field "headers" do
              json.object do
                # Use "contains" instead of "equals" because gRPC HTTP/2 automatically includes
                # :authority and content-type headers, so exact match wouldn't work
                json.field "contains" do
                  json.object do
                    metadata.each { |k, v| json.field k, v }
                  end
                end
              end
            end
          end
        end
      end
      json.field "output" do
        json.raw output
      end
    end
  end
end

describe "gripmock client e2e" do
  it "performs unary success against gripmock" do
    require_gripmock!
    require_gripmock_admin!

    payload = build_stub(
      service: "Probe",
      method: "UnaryEcho",
      input_message: "hello",
      output_message: "echo:hello;token:none",
    )
    require_stub_added!(payload)

    channel = GRPC::Channel.new(gripmock_target)
    begin
      body, status = channel.unary_call("e2e.Probe", "UnaryEcho", E2EProto.encode_string("hello"))
      status.ok?.should be_true
      E2EProto.decode_string(body).should eq("echo:hello;token:none")
    ensure
      channel.close
      gripmock_clear_stubs
    end
  end

  it "maps grpc error status from gripmock" do
    require_gripmock!
    require_gripmock_admin!

    payload = build_stub(
      service: "Probe",
      method: "UnaryFail",
      input_message: "lost",
      output_message: "",
      code: 5,
      error_message: "missing:lost",
    )
    require_stub_added!(payload)

    channel = GRPC::Channel.new(gripmock_target)
    begin
      _body, status = channel.unary_call("e2e.Probe", "UnaryFail", E2EProto.encode_string("lost"))
      status.ok?.should be_false
      status.code.should eq(GRPC::StatusCode::NOT_FOUND)
    ensure
      channel.close
      gripmock_clear_stubs
    end
  end

  it "sends metadata for unary calls" do
    require_gripmock!
    require_gripmock_admin!

    # GripMock DOES support custom header matching in stubs
    payload = build_stub(
      service: "Probe",
      method: "UnaryEcho",
      input_message: "meta",
      metadata: {"x-e2e-token" => "abc123"},
      output_message: "echo:meta;token:abc123",
    )
    require_stub_added!(payload)

    channel = GRPC::Channel.new(gripmock_target)
    begin
      ctx = GRPC::ClientContext.new(metadata: {"x-e2e-token" => "abc123"})
      body, status = channel.unary_call("e2e.Probe", "UnaryEcho", E2EProto.encode_string("meta"), ctx)
      status.ok?.should be_true
      E2EProto.decode_string(body).should eq("echo:meta;token:abc123")
    ensure
      channel.close
      gripmock_clear_stubs
    end
  end

  it "applies deadline on unary calls" do
    require_gripmock!
    require_gripmock_admin!

    payload = build_stub(
      service: "Probe",
      method: "SlowUnary",
      input_message: "sleep",
      output_message: "deadline:ok",
    )
    require_stub_added!(payload)

    channel = GRPC::Channel.new(gripmock_target)
    begin
      ctx = GRPC::ClientContext.new(deadline: 50.milliseconds)
      body, status = channel.unary_call("e2e.Probe", "SlowUnary", E2EProto.encode_string("sleep"), ctx)
      status.ok?.should be_true
      E2EProto.decode_string(body).should eq("deadline:ok")
    ensure
      channel.close
      gripmock_clear_stubs
    end
  end
end
