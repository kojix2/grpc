require "../spec_helper"

# A reproducible property campaign, not a timing-based network simulation.
# Each seed chooses binary messages, compression and transport chunk boundaries.
first_seed = ENV.fetch("GRPC_FUZZ_FIRST_SEED", "20261102").to_u64
seeds = ENV.fetch("GRPC_FUZZ_SEEDS", "32").to_i
raise "GRPC_FUZZ_SEEDS must be positive" unless seeds > 0

describe GRPC::Transport::GrpcDeframer do
  seeds.times do |index|
    seed = first_seed + index
    it "preserves bytes and message order under arbitrary fragmentation (seed #{seed})" do
      random = Random::PCG32.new(seed)
      expected = Array.new(random.rand(1..24)) do
        Bytes.new(random.rand(0..4096)) { random.rand(0..255).to_u8 }
      end
      wire = IO::Memory.new
      expected.each { |bytes| wire.write(GRPC::Codec.encode(bytes, compress: random.rand(2) == 1)) }
      deframer = GRPC::Transport::GrpcDeframer.new(encoding: "gzip", validate_encoding: true)
      actual = [] of Bytes
      offset = 0
      while offset < wire.size
        size = Math.min(random.rand(1..2048), wire.size - offset)
        chunk = wire.to_slice[offset, size].dup
        deframer.append(chunk)
        # Network receive buffers can be reused immediately after append.
        chunk.fill(0_u8)
        actual.concat(deframer.drain_messages)
        offset += size
      end
      actual.should eq(expected)
      deframer.remainder_size.should eq(0)
    end
  end
end
