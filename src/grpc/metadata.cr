module GRPC
  # Metadata represents gRPC metadata (HTTP/2 headers), carrying key-value pairs.
  # Binary-valued keys must end in "-bin" and their values are base64-encoded.
  class Metadata
    def initialize
      @data = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
    end

    def initialize(hash : Hash(String, String))
      @data = Hash(String, Array(String)).new { |store, key| store[key] = [] of String }
      hash.each { |k, v| set(k, v) }
    end

    def set(key : String, value : String) : Nil
      @data[key.downcase] = [value]
    end

    def add(key : String, value : String) : Nil
      @data[key.downcase] << value
    end

    def get(key : String) : String?
      @data[key.downcase]?.try(&.first?)
    end

    def get_all(key : String) : Array(String)
      @data[key.downcase]? || [] of String
    end

    def []?(key : String) : String?
      get(key)
    end

    def []=(key : String, value : String) : String
      set(key, value)
      value
    end

    def each(&block : String, String ->) : Nil
      @data.each do |key, values|
        values.each { |v| block.call(key, v) }
      end
    end

    def to_h : Hash(String, String)
      result = {} of String => String
      @data.each { |k, v| result[k] = v.first if v.first? }
      result
    end

    def empty? : Bool
      @data.empty?
    end

    def merge!(other : Metadata) : self
      other.each { |k, v| add(k, v) }
      self
    end
  end
end
