module GRPC
  module Transport
    # Broadcasts capacity changes to all waiting senders. Reservation happens
    # outside nghttp2 callbacks; releasing it never blocks.
    class SendBudget
      @used = 0_i64
      @mutex = Mutex.new
      @changed = ::Channel(Nil).new

      def initialize(@limit : Int64)
      end

      def acquire(bytes : Int32, closed : ::Channel(Nil), ctx : ClientContext?) : Nil
        if bytes.to_i64 > @limit
          raise StatusError.new(StatusCode::RESOURCE_EXHAUSTED, "message exceeds send buffer limit: #{bytes} > #{@limit}")
        end
        loop do
          ctx.try &.check_active!
          signal = @mutex.synchronize do
            if @used + bytes <= @limit
              @used += bytes
              return
            end
            @changed
          end
          if context = ctx
            if remaining = context.remaining
              select
              when signal.receive?
              when closed.receive?
                raise SendClosedError.new
              when context.cancellation_signal.receive?
                context.check_active!
              when timeout(remaining)
                context.check_active!
              end
            else
              select
              when signal.receive?
              when closed.receive?
                raise SendClosedError.new
              when context.cancellation_signal.receive?
                context.check_active!
              end
            end
          else
            select
            when signal.receive?
            when closed.receive?
              raise SendClosedError.new
            end
          end
        end
      end

      def release(bytes : Int32) : Nil
        return if bytes == 0
        @mutex.synchronize do
          @used -= bytes
          raise "send budget underflow" if @used < 0
          previous = @changed
          @changed = ::Channel(Nil).new
          previous.close
        end
      end
    end
  end
end
