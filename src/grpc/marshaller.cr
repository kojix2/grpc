module GRPC
  # Marshaller converts between typed messages and raw bytes.
  #
  # gRPC transport remains byte-oriented; only typed boundaries should depend
  # on a marshaller.
  abstract class Marshaller(T)
    abstract def encode(value : T) : Bytes
    abstract def decode(bytes : Bytes) : T
  end

  # Default proto marshaller.
  # It delegates to generated message APIs.
  class ProtoMarshaller(T) < Marshaller(T)
    @encoder : (T -> Bytes)?
    @decoder : (Bytes -> T)?

    def initialize
      @encoder = nil
      @decoder = nil
    end

    # The options are generic so existing applications using older generated
    # messages remain compatible with the default constructor.
    def initialize(*, encode_options : E, decode_options : D) forall E, D
      @encoder = ->(value : T) { value.encode(options: encode_options) }
      @decoder = ->(bytes : Bytes) { T.decode(bytes, options: decode_options) }
    end

    def initialize(*, options : ProtobufOptions)
      {% if Proto.has_constant?(:EncodeOptions) && Proto.has_constant?(:DecodeOptions) && T.has_method?(:merge_from_partial) %}
        encode_options = Proto::EncodeOptions.new(max_field_length: options.max_field_length)
        decode_options = Proto::DecodeOptions.new(max_message_size: options.max_message_size,
          max_field_length: options.max_field_length, max_recursion_depth: options.max_recursion_depth)
        @encoder = ->(value : T) { value.encode(options: encode_options) }
        @decoder = ->(bytes : Bytes) { T.decode(bytes, options: decode_options) }
      {% else %}
        @encoder = nil
        @decoder = nil
        raise ArgumentError.new("protobuf options require updated proto.cr and regenerated message types")
      {% end %}
    end

    def encode(value : T) : Bytes
      {% if Proto.has_constant?(:EncodeLimitError) %}
        begin
          encode_value(value)
        rescue ex : Proto::EncodeLimitError
          raise StatusError.new(StatusCode::RESOURCE_EXHAUSTED, "protobuf encode: #{ex.message}", cause: ex)
        end
      {% else %}
        encode_value(value)
      {% end %}
    end

    private def encode_value(value : T) : Bytes
      if encoder = @encoder
        return encoder.call(value)
      end
      value.encode
    end

    def decode(bytes : Bytes) : T
      {% if Proto.has_constant?(:DecodeLimitError) %}
        begin
          decode_value(bytes)
        rescue ex : Proto::DecodeLimitError
          raise StatusError.new(StatusCode::RESOURCE_EXHAUSTED, "protobuf decode: #{ex.message}", cause: ex)
        end
      {% else %}
        decode_value(bytes)
      {% end %}
    end

    private def decode_value(bytes : Bytes) : T
      if decoder = @decoder
        return decoder.call(bytes)
      end
      T.decode(bytes)
    end
  end
end
