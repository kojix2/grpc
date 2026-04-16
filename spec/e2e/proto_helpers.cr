module E2EProto
  def self.encode_string(value : String) : Bytes
    io = IO::Memory.new
    tag = (1 << 3) | 2 # field 1, wire type 2
    encode_varint(io, tag.to_u64)
    encode_varint(io, value.bytesize.to_u64)
    io.write(value.to_slice)
    io.to_slice
  end

  def self.decode_string(data : Bytes) : String
    return "" if data.empty?
    i = 0
    while i < data.size
      tag, consumed = decode_varint(data, i)
      i += consumed
      wire_type = (tag & 0x7).to_i
      field_number = (tag >> 3).to_i
      case wire_type
      when 2
        len, consumed = decode_varint(data, i)
        i += consumed
        return String.new(data[i, len.to_i]) if field_number == 1
        i += len.to_i
      when 0
        _, consumed = decode_varint(data, i)
        i += consumed
      else
        break
      end
    end
    ""
  end

  private def self.encode_varint(io : IO, value : UInt64) : Nil
    loop do
      byte = (value & 0x7F).to_u8
      value >>= 7
      io.write_byte(value != 0 ? (byte | 0x80_u8) : byte)
      break if value == 0
    end
  end

  private def self.decode_varint(data : Bytes, offset : Int32) : {UInt64, Int32}
    result = 0_u64
    shift = 0
    i = 0
    loop do
      break if offset + i >= data.size
      byte = data[offset + i].to_u64
      i += 1
      result |= (byte & 0x7F) << shift
      shift += 7
      break unless (byte & 0x80) != 0
    end
    {result, i}
  end
end
