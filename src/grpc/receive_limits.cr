module GRPC
  # Per-message and per-stream receive budgets. Sizes exclude the 5-byte frame
  # header. A stream may deliver any number of messages over its lifetime.
  struct ReceiveLimits
    DEFAULT_SIZE = 64 * 1024 * 1024

    getter max_wire_size : Int32
    getter max_message_size : Int32
    getter max_buffered_bytes : Int32

    def initialize(@max_wire_size : Int32 = DEFAULT_SIZE,
                   @max_message_size : Int32 = DEFAULT_SIZE,
                   @max_buffered_bytes : Int32 = DEFAULT_SIZE)
      raise ArgumentError.new("max_wire_size must be between 1 and Int32::MAX - 5") unless 0 < @max_wire_size <= Int32::MAX - 5
      raise ArgumentError.new("max_message_size must be between 1 and Int32::MAX - 1") unless 0 < @max_message_size < Int32::MAX
      raise ArgumentError.new("max_buffered_bytes must be positive") unless @max_buffered_bytes > 0
    end
  end
end
