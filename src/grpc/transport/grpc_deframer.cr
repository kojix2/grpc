module GRPC
  module Transport
    # GrpcDeframer incrementally accumulates DATA chunks and extracts complete
    # gRPC messages while preserving any trailing partial frame bytes.
    class GrpcDeframer
      @buffer : Bytes

      def initialize
        @buffer = Bytes.empty
      end

      def append(chunk : Bytes) : Nil
        return if chunk.empty?
        io = IO::Memory.new(@buffer.size + chunk.size)
        io.write(@buffer)
        io.write(chunk)
        @buffer = io.to_slice
      end

      def drain_messages : Array(Bytes)
        messages = [] of Bytes
        data = @buffer
        offset = 0

        while offset + Codec::HEADER_SIZE <= data.size
          length = IO::ByteFormat::BigEndian.decode(UInt32, data[offset + 1, 4]).to_i
          total = Codec::HEADER_SIZE + length
          break if offset + total > data.size

          message, _ = Codec.decode(data[offset, total])
          messages << message
          offset += total
        end

        @buffer = offset < data.size ? data[offset, data.size - offset] : Bytes.empty
        messages
      end

      def remainder_size : Int32
        @buffer.size
      end
    end
  end
end
