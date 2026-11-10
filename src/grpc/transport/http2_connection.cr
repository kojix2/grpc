require "./lib_nghttp2"
require "./unary_message_buffer"
require "base64"
require "socket"
require "openssl"

module GRPC
  module Transport
    module TrailerCodec
      extend self

      def percent_decode(s : String) : String
        result = IO::Memory.new
        i = 0
        while i < s.bytesize
          if s.byte_at(i) == 0x25 && i + 2 < s.bytesize
            high = hex_value(s.byte_at(i + 1))
            low = hex_value(s.byte_at(i + 2))
            if high && low
              result.write_byte((high << 4) | low)
              i += 3
              next
            end
          end
          result.write_byte(s.byte_at(i))
          i += 1
        end
        String.new(result.to_slice)
      end

      private def hex_value(byte : UInt8) : UInt8?
        case byte
        when 0x30_u8..0x39_u8 then byte - 0x30_u8
        when 0x41_u8..0x46_u8 then byte - 0x41_u8 + 10_u8
        when 0x61_u8..0x66_u8 then byte - 0x61_u8 + 10_u8
        end
      end

      def percent_encode(s : String) : String
        String.build do |io|
          s.each_byte do |byte|
            if 0x20 <= byte <= 0x7e && byte != 0x25
              io.write_byte(byte)
            else
              io << '%' << byte.to_s(16, upcase: true).rjust(2, '0')
            end
          end
        end
      end

      def encode_bin(data : Bytes?) : String?
        return unless data
        Base64.strict_encode(data)
      end

      def decode_bin(data : String?) : Bytes?
        return if data.nil? || data.empty?
        decoded = Base64.decode(data)
        canonical = Base64.strict_encode(decoded)
        return decoded if data == canonical || data == canonical.gsub(/=+$/, "")
        nil
      rescue
        nil
      end
    end

    # StreamData accumulates headers and body for one HTTP/2 stream.
    class StreamData
      property headers : Metadata
      property body : IO::Memory
      property header_error : Status?
      property? closed : Bool
      getter received_at = Time.utc

      def initialize(limits : ReceiveLimits = ReceiveLimits.new)
        @headers = Metadata.new
        @message_buffer = UnaryMessageBuffer.new(limits)
        @body = @message_buffer.io
        @header_error = nil
        @closed = false
        @session_active = false
        @close_requested = false
      end

      def body_bytes : Bytes
        @body.to_slice
      end

      def receive_data(chunk : Bytes) : Nil
        @message_buffer.append(chunk)
      end
    end

    # SendBuffer is used as a DataProvider source for outgoing DATA frames.
    class SendBuffer
      property data : Bytes
      property offset : Int32

      def initialize(@data : Bytes)
        @offset = 0
      end

      def remaining : Int32
        @data.size - @offset
      end
    end

    # Http2Connection wraps an nghttp2 session over any IO (plain TCP or TLS).
    # Subclasses implement server-specific or client-specific logic.
    abstract class Http2Connection
      HTTP2_CLIENT_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
      RECV_BUFFER_SIZE     = 65536

      @session : LibNghttp2::Session*
      @socket : IO
      @peer_address : String
      @mutex : Mutex
      @user_data : Void* # GC anchor for Box.box(self)
      @closed : Bool
      @session_active : Bool
      @close_requested : Bool

      def closed? : Bool
        @closed
      end

      def initialize(@socket : IO, @peer_address : String = "unknown")
        @mutex = Mutex.new(:reentrant)
        @closed = false
        @session_active = false
        @close_requested = false
        @user_data = Pointer(Void).null              # filled in subclass after Box.box(self)
        @session = Pointer(LibNghttp2::Session).null # filled in setup_session
      end

      # Subclasses call this inside their own initialize after all fields are set.
      protected def setup_session(server_side : Bool) : Nil
        @user_data = Box.box(self)

        callbacks = Pointer(LibNghttp2::SessionCallbacks).null
        check LibNghttp2.session_callbacks_new(pointerof(callbacks))

        install_callbacks(callbacks)

        options = Pointer(LibNghttp2::Option).null
        check LibNghttp2.option_new(pointerof(options))
        begin
          LibNghttp2.option_set_no_auto_window_update(options, 1)
          if server_side
            check LibNghttp2.session_server_new2(pointerof(@session), callbacks, @user_data, options)
          else
            check LibNghttp2.session_client_new2(pointerof(@session), callbacks, @user_data, options)
          end
        ensure
          LibNghttp2.option_del(options)
        end
        LibNghttp2.session_callbacks_del(callbacks)

        # Send initial SETTINGS
        settings = StaticArray[
          LibNghttp2::SettingsEntry.new(
            settings_id: LibNghttp2::SETTINGS_MAX_CONCURRENT_STREAMS,
            value: 100_u32
          ),
          LibNghttp2::SettingsEntry.new(
            settings_id: LibNghttp2::SETTINGS_INITIAL_WINDOW_SIZE,
            value: 65535_u32
          ),
        ]
        check LibNghttp2.submit_settings(@session, LibNghttp2::FLAG_NONE,
          settings.to_unsafe, settings.size)
        flush_send
      end

      private def install_callbacks(callbacks : LibNghttp2::SessionCallbacks*) : Nil
        LibNghttp2.session_callbacks_set_on_begin_headers_callback(callbacks,
          LibNghttp2::OnBeginHeadersCallback.new do |_, frame, user_data|
            conn = Box(Http2Connection).unbox(user_data)
            conn.invoke_callback { conn.on_begin_headers_cb(frame) }
          end
        )
        LibNghttp2.session_callbacks_set_on_header_callback(callbacks,
          LibNghttp2::OnHeaderCallback.new do |_, frame, name, nlen, value, vlen, _, user_data|
            conn = Box(Http2Connection).unbox(user_data)
            conn.invoke_callback { conn.on_header_cb(frame, name, nlen, value, vlen) }
          end
        )
        LibNghttp2.session_callbacks_set_on_data_chunk_recv_callback(callbacks,
          LibNghttp2::OnDataChunkRecvCallback.new do |_, _, stream_id, data, len, user_data|
            conn = Box(Http2Connection).unbox(user_data)
            conn.invoke_callback { conn.on_data_chunk_cb(stream_id, data, len) }
          end
        )
        LibNghttp2.session_callbacks_set_on_frame_recv_callback(callbacks,
          LibNghttp2::OnFrameRecvCallback.new do |_, frame, user_data|
            conn = Box(Http2Connection).unbox(user_data)
            conn.invoke_callback { conn.on_frame_recv_cb(frame) }
          end
        )
        LibNghttp2.session_callbacks_set_on_frame_send_callback(callbacks,
          LibNghttp2::OnFrameSendCallback.new do |_, frame, user_data|
            conn = Box(Http2Connection).unbox(user_data)
            conn.invoke_callback { conn.on_frame_send_cb(frame) }
          end
        )
        LibNghttp2.session_callbacks_set_on_stream_close_callback(callbacks,
          LibNghttp2::OnStreamCloseCallback.new do |_, stream_id, error_code, user_data|
            conn = Box(Http2Connection).unbox(user_data)
            conn.invoke_callback { conn.on_stream_close_cb(stream_id, error_code) }
          end
        )
      end

      # Do not unwind a Crystal exception through libnghttp2's C stack. The
      # enclosing session operation will fail and tear down the connection.
      def invoke_callback(& : -> Nil) : Int32
        yield
        0
      rescue
        LibNghttp2::ERR_CALLBACK_FAILURE
      end

      # --- Callbacks (called from nghttp2, protected by GIL via @mutex) ---

      def on_begin_headers_cb(frame : Void*) : Nil
      end

      def on_header_cb(frame : Void*, name : UInt8*, nlen : LibC::SizeT,
                       value : UInt8*, vlen : LibC::SizeT) : Nil
      end

      def on_data_chunk_cb(stream_id : Int32, data : UInt8*, len : LibC::SizeT) : Nil
      end

      def on_frame_recv_cb(frame : Void*) : Nil
      end

      def on_frame_send_cb(frame : Void*) : Nil
      end

      def on_stream_close_cb(stream_id : Int32, error_code : UInt32) : Nil
      end

      protected def shutdown_local_state : Nil
      end

      # --- I/O ---

      protected def consume_stream_bytes(stream_id : Int32, bytes : Int32, *, flush : Bool = true) : Nil
        return if bytes <= 0
        @mutex.synchronize do
          return if @closed || @session.null?
          check LibNghttp2.session_consume_stream(@session, stream_id, bytes.to_u64)
          flush_send if flush
        end
      end

      # flush_send writes all pending nghttp2 outbound data to the socket.
      protected def flush_send : Nil
        return if @closed || @session_active
        empty_send_count = 0
        loop do
          data_ptr = Pointer(UInt8).null
          @session_active = true
          begin
            n = session_mem_send(pointerof(data_ptr))
          ensure
            @session_active = false
          end
          if @close_requested
            close
            return
          end
          raise ConnectionError.new("session_mem_send failed: #{String.new(LibNghttp2.strerror(n.to_i32))} (#{n})") if n < 0
          if n == 0
            break if LibNghttp2.session_want_write(@session) == 0
            empty_send_count += 1
            raise ConnectionError.new("session_mem_send made no progress while write work remained") if empty_send_count > 16
            next
          end
          empty_send_count = 0
          @socket.write(Slice.new(data_ptr, n))
        end
        @socket.flush
      rescue ex
        @closed = true
        teardown_session
        @socket.close rescue nil
        raise ex if ex.is_a?(ConnectionError)
        raise ConnectionError.new("HTTP/2 socket write failed: #{ex.message}")
      end

      protected def session_mem_send(data_ptr : UInt8**) : LibC::SSizeT
        LibNghttp2.session_mem_send(@session, data_ptr)
      end

      # run_recv_loop reads from the socket and feeds data to nghttp2.
      # Runs until the connection closes.
      def run_recv_loop : Nil
        buf = Bytes.new(RECV_BUFFER_SIZE)
        loop do
          n = @socket.read(buf)
          break if n == 0
          @mutex.synchronize do
            break if @closed || @session.null?
            @session_active = true
            begin
              result = LibNghttp2.session_mem_recv(@session, buf.to_unsafe, n)
            ensure
              @session_active = false
            end
            break if @close_requested
            if result < 0
              @closed = true
              break
            end
            flush_send
          end
        end
      rescue IO::Error
        # connection closed
      ensure
        close
      end

      def close : Nil
        @mutex.synchronize do
          return if @session.null?
          if @session_active
            @close_requested = true
            return
          end
          @close_requested = false

          begin
            unless @closed
              rc = LibNghttp2.submit_goaway(@session, LibNghttp2::FLAG_NONE, 0, LibNghttp2::NO_ERROR, nil, 0)
              if rc >= 0
                flush_send rescue nil
              end
            end
          ensure
            teardown_session
          end
        end

        @socket.close rescue nil
      end

      private def teardown_session : Nil
        return if @session.null?
        @closed = true
        shutdown_local_state
        LibNghttp2.session_del(@session)
        @session = Pointer(LibNghttp2::Session).null
      end

      # --- Helpers ---

      protected def stream_data_for(stream_id : Int32) : StreamData?
        sd_ptr = LibNghttp2.session_get_stream_user_data(@session, stream_id)
        return if sd_ptr.null?
        Box(StreamData).unbox(sd_ptr)
      end

      protected def frame_stream_id(frame : Void*) : Int32
        frame.as(LibNghttp2::FrameHd*).value.stream_id
      end

      protected def frame_type(frame : Void*) : UInt8
        frame.as(LibNghttp2::FrameHd*).value.type
      end

      protected def frame_flags(frame : Void*) : UInt8
        frame.as(LibNghttp2::FrameHd*).value.flags
      end

      protected def frame_end_stream?(frame : Void*) : Bool
        (frame_flags(frame) & LibNghttp2::FLAG_END_STREAM) != 0
      end

      protected def make_nv(name : String, value : String) : LibNghttp2::Nv
        n = name.to_slice
        v = value.to_slice
        LibNghttp2::Nv.new(
          name: n.to_unsafe,
          value: v.to_unsafe,
          namelen: n.size,
          valuelen: v.size,
          flags: LibNghttp2::NV_FLAG_NONE
        )
      end

      protected def check(rc : Int32, msg : String = "nghttp2 error") : Nil
        return if rc >= 0
        err = String.new(LibNghttp2.strerror(rc))
        raise ConnectionError.new("#{msg}: #{err} (#{rc})")
      end
    end
  end
end
