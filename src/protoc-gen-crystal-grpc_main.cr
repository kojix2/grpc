require "./protoc-gen-crystal-grpc"

buf = IO::Memory.new
IO.copy(STDIN, buf)
request_bytes = buf.to_slice
request = GeneratorRequest.parse(request_bytes)
generator = CrystalGRPCGenerator.new
STDOUT.write(generator.run(request))
