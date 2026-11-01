require "../codec"

module GRPC
  module Transport
    # A unary RPC contains exactly one frame. Validate its header as soon as it
    # arrives and bound accumulation before copying each incoming DATA chunk.
    class UnaryMessageBuffer
      getter io = IO::Memory.new

      def initialize(@limits : ReceiveLimits = ReceiveLimits.new)
      end

      def append(chunk : Bytes) : Nil
        if @io.size.to_i64 + chunk.size > @limits.max_wire_size.to_i64 + Codec::HEADER_SIZE
          raise StatusError.new(StatusCode::RESOURCE_EXHAUSTED, "unary gRPC body exceeds receive limit")
        end
        @io.write(chunk)
        return if @io.size < Codec::HEADER_SIZE
        data = @io.to_slice
        length = Codec.validate_frame_header(data[0], IO::ByteFormat::BigEndian.decode(UInt32, data[1, 4]), @limits)
        if @io.size > Codec::HEADER_SIZE + length
          raise StatusError.new(StatusCode::INTERNAL, "unary RPC must contain exactly one complete gRPC frame")
        end
      end
    end
  end
end
