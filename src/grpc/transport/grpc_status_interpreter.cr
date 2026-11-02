module GRPC
  module Transport
    module GrpcStatusInterpreter
      extend self

      def grpc_status(headers : Metadata, trailers : Metadata, override : Status?) : Status
        return override if override

        code_str = trailers.get("grpc-status") || headers.get("grpc-status")
        unless code_str
          return Status.new(http_status_code(headers), "missing grpc-status trailer")
        end

        code_int = code_str.to_i?
        return Status.unknown("invalid grpc-status: #{code_str}") unless code_int

        message = TrailerCodec.percent_decode(trailers.get("grpc-message") || headers.get("grpc-message") || "")
        details = trailers.get_bin("grpc-status-details-bin") ||
                  headers.get_bin("grpc-status-details-bin")
        code = StatusCode.from_value?(code_int)
        return Status.unknown("invalid grpc-status: #{code_str}") unless code

        Status.new(code, message, details)
      end

      private def http_status_code(headers : Metadata) : StatusCode
        case headers.get(":status").try(&.to_i?)
        when 400                then StatusCode::INTERNAL
        when 401                then StatusCode::UNAUTHENTICATED
        when 403                then StatusCode::PERMISSION_DENIED
        when 404                then StatusCode::UNIMPLEMENTED
        when 429, 502, 503, 504 then StatusCode::UNAVAILABLE
        else                         StatusCode::UNKNOWN
        end
      end

      def application_headers(headers : Metadata) : Metadata
        filtered = Metadata.new
        headers.each_value do |k, v|
          next if k.starts_with?(":")
          next if k == "content-type"
          case v
          when String then filtered.add(k, v)
          when Bytes  then filtered.add_bin(k, v)
          end
        end
        filtered
      end

      def application_trailers(trailers : Metadata) : Metadata
        filtered = Metadata.new
        trailers.each_value do |k, v|
          next if k == "grpc-status" || k == "grpc-message" || k == "grpc-status-details-bin"
          case v
          when String then filtered.add(k, v)
          when Bytes  then filtered.add_bin(k, v)
          end
        end
        filtered
      end
    end
  end
end
