require "../spec_helper"

describe GRPC::Transport::LiveSendBuffer do
  it "accounts for a partially consumed frame until its storage is released" do
    limits = GRPC::SendLimits.new(max_message_size: 32, max_buffered_bytes: 8, max_connection_buffered_bytes: 32)
    buf = GRPC::Transport::LiveSendBuffer.new(0, limits)
    buf.push(Bytes.new(8, 1_u8))
    done = Channel(Nil).new(1)
    spawn { buf.push(Bytes[2]); done.send(nil) }
    output = Bytes.new(8)
    flags = 0_u32
    buf.read_into(output.to_unsafe, 4_u64, pointerof(flags)).should eq(4)
    select
    when done.receive
      fail "sender advanced while the previous frame was still retained"
    when timeout(10.milliseconds)
    end
    buf.read_into(output.to_unsafe, 4_u64, pointerof(flags)).should eq(4)
    select
    when done.receive
    when timeout(1.second)
      fail "sender did not wake when frame storage was released"
    end
    buf.abort
  end

  it "shares a connection budget across independent streams" do
    limits = GRPC::SendLimits.new(max_message_size: 32, max_buffered_bytes: 8, max_connection_buffered_bytes: 8)
    budget = GRPC::Transport::SendBudget.new(8_i64)
    first = GRPC::Transport::LiveSendBuffer.new(0, limits, budget)
    second = GRPC::Transport::LiveSendBuffer.new(0, limits, budget)
    first.push(Bytes.new(6))
    done = Channel(Nil).new(1)
    spawn { second.push(Bytes.new(4)); done.send(nil) }
    Fiber.yield
    select
    when done.receive
      fail "connection budget was not enforced"
    when timeout(10.milliseconds)
    end
    first.abort
    select
    when done.receive
    when timeout(1.second)
      fail "aborting the first stream did not free its connection budget"
    end
    second.abort
  end

  it "releases a byte-budget waiter when its context is cancelled" do
    limits = GRPC::SendLimits.new(max_message_size: 32, max_buffered_bytes: 8, max_connection_buffered_bytes: 32)
    ctx = GRPC::ClientContext.new
    buf = GRPC::Transport::LiveSendBuffer.new(0, limits, context: ctx)
    buf.push(Bytes.new(8))
    done = Channel(GRPC::StatusCode).new(1)
    spawn do
      buf.push(Bytes[1])
    rescue ex : GRPC::StatusError
      done.send(ex.code)
    end
    Fiber.yield
    ctx.cancel
    select
    when code = done.receive
      code.should eq(GRPC::StatusCode::CANCELLED)
    when timeout(1.second)
      fail "cancel did not wake the byte-budget waiter"
    end
    buf.abort
  end

  it "rejects a frame larger than its byte budget without waiting" do
    limits = GRPC::SendLimits.new(max_message_size: 32, max_buffered_bytes: 8, max_connection_buffered_bytes: 32)
    buf = GRPC::Transport::LiveSendBuffer.new(0, limits)
    error = expect_raises(GRPC::StatusError) { buf.push(Bytes.new(9)) }
    error.code.should eq(GRPC::StatusCode::RESOURCE_EXHAUSTED)
  end

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
