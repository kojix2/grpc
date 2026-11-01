module GrpcFrameSpec
  def self.frame_header(flag : UInt8, length : UInt32) : Bytes
    io = IO::Memory.new
    io.write_byte(flag)
    io.write_bytes(length, IO::ByteFormat::BigEndian)
    io.to_slice
  end
end
