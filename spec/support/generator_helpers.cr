require "../spec_helper"
require "../../src/protoc-gen-crystal-grpc"

module GrpcGeneratorSpec
  module TestProtoEncode
    def self.varint(io : IO, v : UInt64) : Nil
      loop do
        b = (v & 0x7F).to_u8
        v >>= 7
        io.write_byte(v != 0 ? b | 0x80_u8 : b)
        break if v == 0
      end
    end

    def self.string(io : IO, field : Int32, value : String) : Nil
      return if value.empty?
      bytes = value.to_slice
      varint(io, ((field << 3) | 2).to_u64)
      varint(io, bytes.size.to_u64)
      io.write(bytes)
    end

    def self.bool(io : IO, field : Int32, value : Bool) : Nil
      return unless value
      varint(io, ((field << 3) | 0).to_u64)
      varint(io, 1_u64)
    end

    def self.embedded(io : IO, field : Int32, & : IO ->) : Nil
      tmp = IO::Memory.new
      yield tmp
      data = tmp.to_slice
      return if data.empty?
      varint(io, ((field << 3) | 2).to_u64)
      varint(io, data.size.to_u64)
      io.write(data)
    end

    # Build a MethodDescriptorProto
    def self.method_proto(name : String, input_type : String, output_type : String,
                          client_streaming : Bool = false, server_streaming : Bool = false) : Bytes
      io = IO::Memory.new
      string(io, 1, name)
      string(io, 2, input_type)
      string(io, 3, output_type)
      bool(io, 5, client_streaming)
      bool(io, 6, server_streaming)
      io.to_slice
    end

    # Build a ServiceDescriptorProto
    def self.service_proto(name : String, methods : Array(Bytes)) : Bytes
      io = IO::Memory.new
      string(io, 1, name)
      methods.each do |method_bytes|
        varint(io, ((2 << 3) | 2).to_u64)
        varint(io, method_bytes.size.to_u64)
        io.write(method_bytes)
      end
      io.to_slice
    end

    # Build a FileDescriptorProto
    def self.file_proto(name : String, package : String, services : Array(Bytes)) : Bytes
      io = IO::Memory.new
      string(io, 1, name)
      string(io, 2, package)
      services.each do |svc_bytes|
        varint(io, ((6 << 3) | 2).to_u64)
        varint(io, svc_bytes.size.to_u64)
        io.write(svc_bytes)
      end
      io.to_slice
    end

    # Build a CodeGeneratorRequest
    def self.request(files_to_generate : Array(String), proto_files : Array(Bytes), parameter : String = "") : Bytes
      io = IO::Memory.new
      files_to_generate.each { |fname| string(io, 1, fname) }
      string(io, 2, parameter)
      proto_files.each do |file_bytes|
        varint(io, ((15 << 3) | 2).to_u64)
        varint(io, file_bytes.size.to_u64)
        io.write(file_bytes)
      end
      io.to_slice
    end
  end

  def self.run_generator(request_bytes : Bytes, output_file : String) : String
    request = parse_request(request_bytes)
    generator = CrystalGrpcCodeGenerator.new
    response_bytes = generator.run(request)
    extract_file_content(response_bytes, output_file) ||
      fail("Expected #{output_file} to be generated")
  end

  def self.parse_request(data : Bytes) : PluginCodeGeneratorRequest
    PluginCodeGeneratorRequest.read_proto(IO::Memory.new(data))
  end

  # Parse the CodeGeneratorResponse binary and return the content of the named
  # file, or nil if not found.
  def self.extract_file_content(response : Bytes, filename : String) : String?
    parsed = Proto::Bootstrap::CodeGeneratorResponse.decode(IO::Memory.new(response))
    parsed.file.each do |response_file|
      return response_file.content if response_file.name == filename
    end
    nil
  end
end
