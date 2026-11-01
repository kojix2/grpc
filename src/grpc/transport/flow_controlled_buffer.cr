require "./grpc_deframer"

module GRPC
  module Transport
    class FlowControlledBuffer
      getter messages : ::Channel(Bytes?)
      property consumed : Int32 -> Nil
      getter deframer : GrpcDeframer
      property error_status : Status?
      @pending = Deque(Tuple(Bytes, Int32)).new
      @state_mutex = Mutex.new
      @outstanding = 0
      @preconsumed = 0
      @delivering = false
      @finished = false

      def initialize(@consumed : Int32 -> Nil = ->(_bytes : Int32) { })
        # An unbuffered handoff makes consumption observable even when a
        # generated RequestStream wraps requests.ch directly.
        @messages = ::Channel(Bytes?).new
        @deframer = GrpcDeframer.new(validate_encoding: true)
        @error_status = nil
        @closed = Atomic(Bool).new(false)
      end

      def append(chunk : Bytes) : Int32
        @state_mutex.synchronize do
          return 0 if @closed.get || @finished
          @deframer.append(chunk)
          @deframer.drain_frames.each do |message, wire_size|
            @pending << {message, wire_size - @preconsumed}
            @preconsumed = 0
            @outstanding += 1
          end
          unless @pending.empty? || @delivering
            @delivering = true
            spawn deliver
          end
          # A message larger than the HTTP/2 window must be assembled before
          # it can be handed off. Credit its partial bytes only while no
          # complete message is awaiting consumption. Completed backlogs earn
          # no fresh credit; the advertised stream window applies backpressure.
          partial_credit
        end
      end

      def finish : Nil
        @state_mutex.synchronize do
          @finished = true
          @messages.close if @outstanding == 0 && !@messages.closed?
        end
      end

      def close : Nil
        # compare_and_set returns {old_value, success?}; only the winner executes.
        return unless @closed.compare_and_set(false, true)[1]
        @state_mutex.synchronize do
          @pending.clear
          @messages.close
        end
      rescue
        # no-op
      end

      private def deliver : Nil
        loop do
          item = @state_mutex.synchronize do
            if @closed.get || @pending.empty?
              @delivering = false
              @messages.close if @finished && !@messages.closed?
              nil
            else
              @pending.shift
            end
          end
          break unless item
          message, credit = item
          @messages.send(message)
          credit += @state_mutex.synchronize do
            @outstanding -= 1
            partial_credit
          end
          # Never call transport/window code while holding the state lock or
          # from a blocking nghttp2 callback.
          @consumed.call(credit) if credit > 0
        end
      rescue ::Channel::ClosedError
        # Cancellation interrupts an outstanding handoff.
      rescue ex
        @error_status = Status.internal(ex.message || "stream delivery failed")
        close
      end

      private def partial_credit : Int32
        return 0 unless @outstanding == 0
        credit = @deframer.remainder_size - @preconsumed
        @preconsumed = @deframer.remainder_size
        credit
      end
    end
  end
end
