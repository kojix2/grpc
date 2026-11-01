struct DummyMessage
  getter value : String

  def initialize(@value : String)
  end

  def encode : Bytes
    @value.to_slice
  end

  def self.decode(bytes : Bytes) : self
    new(String.new(bytes))
  end
end

class TestDummyMarshaller < GRPC::Marshaller(DummyMessage)
  def encode(value : DummyMessage) : Bytes
    ("out:" + value.value).to_slice
  end

  def decode(bytes : Bytes) : DummyMessage
    DummyMessage.new("in:" + String.new(bytes))
  end
end
