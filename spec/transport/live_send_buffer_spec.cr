require "../spec_helper"

describe GRPC::Transport::LiveSendBuffer do
  it "unbounded mode: push never blocks" do
    buf = GRPC::Transport::LiveSendBuffer.new(0)
    100.times { |i| buf.push(Bytes[i.to_u8]) }
  end

  it "bounded mode: blocks when full, unblocks when drained" do
    buf = GRPC::Transport::LiveSendBuffer.new(2)

    # Fill queue to capacity without blocking
    buf.push(Bytes[1_u8])
    buf.push(Bytes[2_u8])

    unblocked = false

    # Third push should block until read_into drains one entry
    spawn do
      buf.push(Bytes[3_u8])
      unblocked = true
    end

    Fiber.yield

    # The spawned fiber should still be blocked
    unblocked.should be_false

    # Simulate DATA_READ_CB_LIVE draining one chunk via read_into
    raw_buf = Bytes.new(64)
    flags = 0_u32
    buf.read_into(raw_buf.to_unsafe, 64_u64, pointerof(flags))

    Fiber.yield

    # Now the slot is free and the push should have completed
    unblocked.should be_true
  end

  it "bounded mode: close after full push unblocks reads with EOF" do
    buf = GRPC::Transport::LiveSendBuffer.new(1)
    buf.push(Bytes[42_u8])
    buf.close

    raw_buf = Bytes.new(64)
    flags = 0_u32
    bytes_read = buf.read_into(raw_buf.to_unsafe, 64_u64, pointerof(flags))
    bytes_read.should eq(1)

    # Second call: queue empty and closed → EOF
    flags2 = 0_u32
    buf.read_into(raw_buf.to_unsafe, 64_u64, pointerof(flags2))
    (flags2 & LibNghttp2::DATA_FLAG_EOF).should_not eq(0)
  end

  it "bounded mode: close releases a sender waiting for capacity" do
    buf = GRPC::Transport::LiveSendBuffer.new(1)
    buf.push(Bytes[1_u8])
    result = ::Channel(Exception?).new(1)

    spawn do
      buf.push(Bytes[2_u8])
      result.send(nil)
    rescue ex
      result.send(ex)
    end
    Fiber.yield
    buf.close

    select
    when ex = result.receive
      ex.should be_a(GRPC::StatusError)
    when timeout(100.milliseconds)
      fail("blocked sender was not released by close")
    end
  end
end
