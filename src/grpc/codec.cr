require "compress/gzip"
require "./receive_limits"

module GRPC
  # Codec handles gRPC message framing and optional gzip compression.
  #
  # Each gRPC message is prefixed with a 5-byte header:
  #   Byte 0:    Compressed-Flag (0 = not compressed, 1 = gzip compressed)
  #   Bytes 1-4: Message-Length (big-endian uint32) — length of the (possibly compressed) body
  module Codec
    HEADER_SIZE = 5

    # Encode a protobuf-serialized message into a gRPC DATA frame payload.
    # Pass `compress: true` to gzip-compress the payload.
    def self.encode(message_bytes : Bytes, compress : Bool = false) : Bytes
      if compress
        compressed = compress_gzip(message_bytes)
        io = IO::Memory.new(HEADER_SIZE + compressed.size)
        io.write_byte(1_u8)
        io.write_bytes(compressed.size.to_u32, IO::ByteFormat::BigEndian)
        io.write(compressed)
      else
        io = IO::Memory.new(HEADER_SIZE + message_bytes.size)
        io.write_byte(0_u8)
        io.write_bytes(message_bytes.size.to_u32, IO::ByteFormat::BigEndian)
        io.write(message_bytes)
      end
      io.to_slice
    end

    # Decode reads one gRPC message from the given Bytes slice.
    # Returns {message_bytes, bytes_consumed}.
    # Decompresses gzip-compressed frames automatically.
    # Raises StatusError on incomplete or malformed frames.
    def self.decode(data : Bytes, encoding : String? = nil,
                    validate_encoding : Bool = false,
                    limits : ReceiveLimits = ReceiveLimits.new) : {Bytes, Int32}
      raise StatusError.new(StatusCode::INTERNAL, "incomplete gRPC frame header") if data.size < HEADER_SIZE

      compressed = data[0]
      length = validate_frame_header(compressed, IO::ByteFormat::BigEndian.decode(UInt32, data[1, 4]), limits)
      total = HEADER_SIZE + length

      raise StatusError.new(StatusCode::INTERNAL, "incomplete gRPC frame body") if data.size < total

      body = data[HEADER_SIZE, length]
      {decode_payload(compressed, body, encoding, validate_encoding, limits), total}
    end

    # Bytes and deframer offsets use Int32. Validate the unsigned wire length
    # before conversion or adding the header, and reject bad flags immediately.
    def self.validate_frame_header(compressed : UInt8, length : UInt32,
                                   limits : ReceiveLimits = ReceiveLimits.new) : Int32
      unless compressed == 0 || compressed == 1
        raise StatusError.new(StatusCode::UNIMPLEMENTED, "unsupported gRPC compression flag: #{compressed}")
      end
      if length > (Int32::MAX - HEADER_SIZE).to_u32
        raise StatusError.new(StatusCode::RESOURCE_EXHAUSTED, "gRPC frame length exceeds supported limit")
      end
      if length > limits.max_wire_size.to_u32 || (compressed == 0 && length > limits.max_message_size.to_u32)
        raise StatusError.new(StatusCode::RESOURCE_EXHAUSTED, "gRPC message exceeds receive limit")
      end
      length.to_i
    end

    def self.decode_payload(compressed : UInt8, body : Bytes,
                            encoding : String? = nil,
                            validate_encoding : Bool = false,
                            limits : ReceiveLimits = ReceiveLimits.new) : Bytes
      validate_encoding!(encoding) if validate_encoding
      if body.size > limits.max_wire_size
        raise StatusError.new(StatusCode::RESOURCE_EXHAUSTED, "gRPC message exceeds receive limit")
      end
      # Keep the uncompressed path as a borrowed slice; only gzip requires a
      # fresh allocation for the decompressed payload.
      if compressed == 1
        if validate_encoding && encoding != "gzip"
          raise StatusError.new(StatusCode::UNIMPLEMENTED,
            "compressed gRPC message requires grpc-encoding: gzip")
        end
        decompress_gzip(body, limits.max_message_size)
      elsif compressed == 0
        if body.size > limits.max_message_size
          raise StatusError.new(StatusCode::RESOURCE_EXHAUSTED, "gRPC message exceeds receive limit")
        end
        body
      else
        raise StatusError.new(StatusCode::UNIMPLEMENTED, "unsupported gRPC compression flag: #{compressed}")
      end
    end

    def self.validate_encoding!(encoding : String?) : Nil
      return if encoding.nil? || encoding == "identity" || encoding == "gzip"
      raise StatusError.new(StatusCode::UNIMPLEMENTED,
        "unsupported grpc-encoding: #{encoding}")
    end

    # Decode all gRPC messages from the given Bytes slice.
    def self.decode_all(data : Bytes, limits : ReceiveLimits = ReceiveLimits.new) : Array(Bytes)
      messages = [] of Bytes
      offset = 0
      decoded_size = 0_i64
      while offset < data.size
        msg, consumed = decode(data[offset..], limits: limits)
        decoded_size += msg.size
        if decoded_size > limits.max_buffered_bytes
          raise StatusError.new(StatusCode::RESOURCE_EXHAUSTED, "decoded gRPC batch exceeds receive buffer limit")
        end
        messages << msg
        offset += consumed
      end
      messages
    end

    private def self.compress_gzip(data : Bytes) : Bytes
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io, &.write(data))
      io.to_slice
    end

    private def self.decompress_gzip(data : Bytes, max_size : Int32) : Bytes
      # The gzip reader permits a file containing no members. A compressed
      # gRPC frame must contain an actual gzip member, even for an empty message.
      raise StatusError.new(StatusCode::INTERNAL, "empty gzip payload") if data.empty?
      decoded = IO::Memory.new
      Compress::Gzip::Reader.open(IO::Memory.new(data)) do |reader|
        # Read one sentinel byte beyond the budget, never the unbounded output.
        IO.copy(reader, decoded, max_size.to_i64 + 1)
      end
      if decoded.size > max_size
        raise StatusError.new(StatusCode::RESOURCE_EXHAUSTED, "decompressed gRPC message exceeds receive limit")
      end
      decoded.to_slice
    rescue ex : IO::Error | Compress::Gzip::Error | Compress::Deflate::Error
      raise StatusError.new(StatusCode::INTERNAL, "invalid gzip payload: #{ex.message}", cause: ex)
    end
  end
end
