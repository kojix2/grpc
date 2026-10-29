require "./spec_helper"

class StreamingBufferProbe < GRPC::Transport::Http2ServerConnection
  def initialize
    super(IO::Memory.new, {} of String => GRPC::Service)
  end

  def stage_buffer : GRPC::Transport::SendBuffer
    buffer = GRPC::Transport::SendBuffer.new(Bytes.new(32 * 1024))
    @stream_send_bufs[1] = buffer
    @stream_send_boxes[1] = [Box.box(buffer)]
    @stream_data_in_flight.add(1)
    buffer
  end

  def finish_data_frame : Nil
    frame = LibNghttp2::FrameHd.new(stream_id: 1, type: LibNghttp2::FRAME_DATA)
    on_frame_send_cb(pointerof(frame).as(Void*))
  end

  def send_chunk : Nil
    send_stream_chunk(1, GRPC::Codec.encode(Bytes[1]))
  end

  def queued_chunks : Int32
    @stream_pending_chunks[1]?.try(&.size) || 0
  end

  def retained_buffers : Int32
    @stream_send_bufs.size
  end

  def retained_boxes : Int32
    @stream_send_boxes.values.sum(&.size)
  end

  def data_in_flight? : Bool
    @stream_data_in_flight.includes?(1)
  end
end

describe "GRPC streaming send buffers" do
  it "keeps a partially sent message alive across DATA frames" do
    connection = StreamingBufferProbe.new
    begin
      buffer = connection.stage_buffer
      connection.send_chunk
      buffer.offset = 16 * 1024
      connection.finish_data_frame

      connection.data_in_flight?.should be_true
      connection.queued_chunks.should eq(1)
      connection.retained_buffers.should eq(1)
      connection.retained_boxes.should eq(1)
    ensure
      connection.close
    end
  end

  it "releases a fully sent message and its GC anchor before the stream closes" do
    connection = StreamingBufferProbe.new
    begin
      buffer = connection.stage_buffer
      buffer.offset = buffer.data.size
      connection.finish_data_frame

      connection.data_in_flight?.should be_false
      connection.retained_buffers.should eq(0)
      connection.retained_boxes.should eq(0)
    ensure
      connection.close
    end
  end

  it "bounds a stalled consumer's queue and returns RESOURCE_EXHAUSTED" do
    connection = StreamingBufferProbe.new
    begin
      connection.stage_buffer
      8.times { connection.send_chunk }
      error = expect_raises(GRPC::StatusError, "HTTP/2 consumer stalled") do
        connection.send_chunk
      end
      error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
      connection.queued_chunks.should eq(8)
    ensure
      connection.close
    end
  end

  it "allows connection shutdown while a sender waits for queue space" do
    connection = StreamingBufferProbe.new
    connection.stage_buffer
    8.times { connection.send_chunk }
    result = ::Channel(Exception?).new(1)
    spawn do
      begin
        connection.send_chunk
        result.send(nil)
      rescue ex
        result.send(ex)
      end
    end
    Fiber.yield
    connection.close

    select
    when error = result.receive
      error.should be_a(GRPC::ConnectionError)
    when timeout(1.second)
      fail "blocked streaming sender prevented connection shutdown"
    end
  ensure
    connection.try(&.close)
  end

  it "rejects sends after the connection closes" do
    connection = StreamingBufferProbe.new
    connection.close
    expect_raises(GRPC::ConnectionError, "stream closed") { connection.send_chunk }
  end
end
