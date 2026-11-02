class ReflectionRegistryProbeService < GRPC::Service
  SERVICE_FULL_NAME = "demo.Greeter"

  def service_full_name : String
    SERVICE_FULL_NAME
  end

  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    _ = method
    _ = request_body
    _ = ctx
    {Bytes.empty, GRPC::Status.ok}
  end
end

module ReflectionSpecWire
  LABEL_OPTIONAL = 1_u64
  TYPE_STRING    = 9_u64

  def self.encode_request(field_number : Int32, value : String) : Bytes
    io = IO::Memory.new
    GRPC::Reflection::Wire.write_string(io, field_number, value)
    io.to_slice
  end

  def self.decode_list_services_response(bytes : Bytes) : Array(String)
    decode_message_response(bytes, 6) do |payload|
      names = [] of String
      cursor = 0
      while cursor < payload.size
        tag, cursor = GRPC::Reflection::Wire.read_varint(payload, cursor)
        field_number = (tag >> 3).to_i32
        wire_type = (tag & 0x7_u64).to_i32
        if field_number == 1 && wire_type == 2
          entry, cursor = GRPC::Reflection::Wire.read_bytes(payload, cursor)
          names << decode_service_name(entry)
        else
          cursor = GRPC::Reflection::Wire.skip_field(payload, cursor, wire_type)
        end
      end
      names
    end
  end

  def self.decode_file_descriptor_response(bytes : Bytes) : Array(Bytes)
    decode_message_response(bytes, 4) do |payload|
      descriptors = [] of Bytes
      cursor = 0
      while cursor < payload.size
        tag, cursor = GRPC::Reflection::Wire.read_varint(payload, cursor)
        field_number = (tag >> 3).to_i32
        wire_type = (tag & 0x7_u64).to_i32
        if field_number == 1 && wire_type == 2
          descriptor, cursor = GRPC::Reflection::Wire.read_bytes(payload, cursor)
          descriptors << descriptor
        else
          cursor = GRPC::Reflection::Wire.skip_field(payload, cursor, wire_type)
        end
      end
      descriptors
    end
  end

  def self.build_demo_file_descriptor_proto(request_name : String = "HelloRequest", reply_name : String = "HelloReply") : Bytes
    io = IO::Memory.new
    GRPC::Reflection::Wire.write_string(io, 1, "demo.proto")
    GRPC::Reflection::Wire.write_string(io, 2, "demo")
    GRPC::Reflection::Wire.write_bytes(io, 4, build_string_message_descriptor(request_name))
    GRPC::Reflection::Wire.write_bytes(io, 4, build_string_message_descriptor(reply_name))
    GRPC::Reflection::Wire.write_bytes(io, 6, build_service_descriptor(request_name, reply_name))
    io.to_slice
  end

  def self.decode_error_response(bytes : Bytes) : {Int32, String}
    decode_message_response(bytes, 7) do |payload|
      code = 0
      message = ""
      cursor = 0
      while cursor < payload.size
        tag, cursor = GRPC::Reflection::Wire.read_varint(payload, cursor)
        field_number = (tag >> 3).to_i32
        wire_type = (tag & 0x7_u64).to_i32
        case field_number
        when 1
          if wire_type == 0
            value, cursor = GRPC::Reflection::Wire.read_varint(payload, cursor)
            code = value.to_i32
          else
            cursor = GRPC::Reflection::Wire.skip_field(payload, cursor, wire_type)
          end
        when 2
          if wire_type == 2
            message, cursor = GRPC::Reflection::Wire.read_string(payload, cursor)
          else
            cursor = GRPC::Reflection::Wire.skip_field(payload, cursor, wire_type)
          end
        else
          cursor = GRPC::Reflection::Wire.skip_field(payload, cursor, wire_type)
        end
      end
      {code, message}
    end
  end

  private def self.decode_message_response(bytes : Bytes, response_field_number : Int32, & : Bytes -> T) : T forall T
    cursor = 0

    while cursor < bytes.size
      tag, cursor = GRPC::Reflection::Wire.read_varint(bytes, cursor)
      field_number = (tag >> 3).to_i32
      wire_type = (tag & 0x7_u64).to_i32
      if field_number == response_field_number && wire_type == 2
        payload, _ = GRPC::Reflection::Wire.read_bytes(bytes, cursor)
        return yield payload
      end
      cursor = GRPC::Reflection::Wire.skip_field(bytes, cursor, wire_type)
    end

    raise "missing reflection response payload"
  end

  private def self.decode_service_name(bytes : Bytes) : String
    cursor = 0
    while cursor < bytes.size
      tag, cursor = GRPC::Reflection::Wire.read_varint(bytes, cursor)
      field_number = (tag >> 3).to_i32
      wire_type = (tag & 0x7_u64).to_i32
      if field_number == 1 && wire_type == 2
        name, _ = GRPC::Reflection::Wire.read_string(bytes, cursor)
        return name
      end
      cursor = GRPC::Reflection::Wire.skip_field(bytes, cursor, wire_type)
    end
    raise "missing service name"
  end

  private def self.build_string_message_descriptor(name : String) : Bytes
    io = IO::Memory.new
    GRPC::Reflection::Wire.write_string(io, 1, name)
    GRPC::Reflection::Wire.write_bytes(io, 2, build_string_field_descriptor)
    io.to_slice
  end

  private def self.build_string_field_descriptor : Bytes
    io = IO::Memory.new
    GRPC::Reflection::Wire.write_string(io, 1, "message")
    GRPC::Reflection::Wire.write_varint_field(io, 3, 1_u64)
    GRPC::Reflection::Wire.write_varint_field(io, 4, LABEL_OPTIONAL)
    GRPC::Reflection::Wire.write_varint_field(io, 5, TYPE_STRING)
    io.to_slice
  end

  private def self.build_service_descriptor(request_name : String, reply_name : String) : Bytes
    io = IO::Memory.new
    GRPC::Reflection::Wire.write_string(io, 1, "Greeter")
    GRPC::Reflection::Wire.write_bytes(io, 2, build_method_descriptor(request_name, reply_name))
    io.to_slice
  end

  private def self.build_method_descriptor(request_name : String, reply_name : String) : Bytes
    io = IO::Memory.new
    GRPC::Reflection::Wire.write_string(io, 1, "SayHello")
    GRPC::Reflection::Wire.write_string(io, 2, ".demo.#{request_name}")
    GRPC::Reflection::Wire.write_string(io, 3, ".demo.#{reply_name}")
    io.to_slice
  end
end
