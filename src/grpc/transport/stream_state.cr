module GRPC
  module Transport
    # StreamHeaderState tracks whether incoming HEADERS belong to initial
    # response headers or trailing headers.
    class StreamHeaderState
      getter headers : Metadata
      getter trailers : Metadata

      def initialize
        @headers = Metadata.new
        @trailers = Metadata.new
        @receiving_trailers = false
      end

      def begin_header_block : Nil
        @receiving_trailers = !@headers.empty?
      end

      def add_header(key : String, value : String) : Nil
        target = @receiving_trailers ? @trailers : @headers
        target.add_wire(key, value)
      end
    end

    # StreamTerminalState centralizes one-way terminal stream transitions.
    class StreamTerminalState
      def initialize
        @finished = false
        @cancelled = false
      end

      def mark_finished : Bool
        return false if @finished
        @finished = true
        true
      end

      def mark_cancelled : Bool
        return false if @cancelled
        @cancelled = true
        true
      end

      def finished? : Bool
        @finished
      end

      def cancelled? : Bool
        @cancelled
      end
    end
  end
end
