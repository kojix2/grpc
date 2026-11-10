module GRPC
  # Limits for encoded outgoing messages and bytes retained by send queues.
  struct SendLimits
    DEFAULT_MESSAGE_SIZE = 64 * 1024 * 1024

    getter max_message_size : Int32
    getter max_buffered_bytes : Int32
    getter max_connection_buffered_bytes : Int64

    def initialize(@max_message_size : Int32 = DEFAULT_MESSAGE_SIZE,
                   @max_buffered_bytes : Int32 = DEFAULT_MESSAGE_SIZE + 5,
                   @max_connection_buffered_bytes : Int64 = 256_i64 * 1024 * 1024)
      raise ArgumentError.new("max_message_size must be positive") unless @max_message_size > 0
      raise ArgumentError.new("max_buffered_bytes must be positive") unless @max_buffered_bytes > 0
      raise ArgumentError.new("max_connection_buffered_bytes must be positive") unless @max_connection_buffered_bytes > 0
    end
  end
end
