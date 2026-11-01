require "../spec_helper"

describe GRPC::Metadata do
  describe "text values" do
    it "can be constructed from a Hash" do
      m = GRPC::Metadata.new({"x-foo" => "bar"})
      m.get("x-foo").should eq("bar")
    end

    it "sets and gets values" do
      m = GRPC::Metadata.new
      m.set("x-request-id", "abc123")
      m.get("x-request-id").should eq("abc123")
    end

    it "normalises keys to lowercase" do
      m = GRPC::Metadata.new
      m.set("X-Custom-Header", "value")
      m.get("x-custom-header").should eq("value")
    end

    it "accumulates multiple values" do
      m = GRPC::Metadata.new
      m.add("x-tag", "a")
      m.add("x-tag", "b")
      m.get_all("x-tag").should eq(["a", "b"])
    end
  end

  describe "binary values" do
    it "stores binary metadata separately from text metadata" do
      m = GRPC::Metadata.new
      m.add_bin("trace-bin", Bytes[1, 2, 3])

      m.get("trace-bin").should be_nil
      m.get_bin("trace-bin").should eq(Bytes[1, 2, 3])
      m.to_h["trace-bin"].should eq("AQID")
    end

    it "decodes wire-format binary metadata" do
      m = GRPC::Metadata.new
      m.add_wire("trace-bin", "AQID")

      m.get_bin("trace-bin").should eq(Bytes[1, 2, 3])
    end
  end

  describe "copying" do
    it "dup duplicates binary metadata values" do
      original = GRPC::Metadata.new
      bytes = Bytes[4, 5, 6]
      original.add_bin("trace-bin", bytes)

      copy = original.dup
      bytes[0] = 9

      original.get_bin("trace-bin").should eq(Bytes[4, 5, 6])
      copy.get_bin("trace-bin").should eq(Bytes[4, 5, 6])

      original_bin = original.get_bin("trace-bin")
      copy_bin = copy.get_bin("trace-bin")
      if original_bin && copy_bin
        copy_bin.should_not be(original_bin)
      end
    end

    it "merge! duplicates binary metadata values" do
      source = GRPC::Metadata.new
      bytes = Bytes[1, 2, 3]
      source.add_bin("trace-bin", bytes)

      merged = GRPC::Metadata.new
      merged.merge!(source)
      bytes[0] = 9

      source.get_bin("trace-bin").should eq(Bytes[1, 2, 3])
      merged.get_bin("trace-bin").should eq(Bytes[1, 2, 3])

      source_bin = source.get_bin("trace-bin")
      merged_bin = merged.get_bin("trace-bin")
      if source_bin && merged_bin
        merged_bin.should_not be(source_bin)
      end
    end
  end

  describe "invalid values" do
    it "rejects text values for binary metadata keys" do
      m = GRPC::Metadata.new

      expect_raises(ArgumentError) do
        m.add("trace-bin", "AQID")
      end
    end

    it "rejects binary values for text metadata keys" do
      m = GRPC::Metadata.new

      expect_raises(ArgumentError) do
        m.add_bin("trace", Bytes[1, 2, 3])
      end
    end

    it "rejects invalid wire-format binary metadata" do
      m = GRPC::Metadata.new

      expect_raises(ArgumentError) do
        m.add_wire("trace-bin", "!!!")
      end
    end
  end
end
