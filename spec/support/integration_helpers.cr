require "./integration_services"

def find_free_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

def start_test_server(port : Int32) : GRPC::Server
  server = GRPC::Server.new
  server.handle EchoService.new
  server.bind("127.0.0.1:#{port}")
  server.start
  server
end

TLS_CERT = File.join(__DIR__, "../test.crt")
TLS_KEY  = File.join(__DIR__, "../test.key")
