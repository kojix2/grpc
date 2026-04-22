require "./health/v1/health.pb"
require "./health/v1/health.grpc"

module GRPC
  module Health
    alias ServingStatus = ::Grpc::Health::V1::HealthCheckResponse::ServingStatus

    def self.generated_check_response(status : ServingStatus) : ::Grpc::Health::V1::HealthCheckResponse
      response = ::Grpc::Health::V1::HealthCheckResponse.new
      response.status = Proto::OpenEnum(ServingStatus).new(status)
      response
    end

    def self.serving_status_from_wire(status : Proto::OpenEnum(ServingStatus)) : ServingStatus
      status.known || ServingStatus::UNKNOWN
    end

    class Registry
      @mutex : Mutex
      @statuses : Hash(String, ServingStatus)
      @watchers : Hash(String, Array(::Channel(ServingStatus)))
      @overall_default_status : ServingStatus

      def initialize(default_status : ServingStatus = ServingStatus::SERVING)
        @mutex = Mutex.new
        @statuses = {"" => default_status} of String => ServingStatus
        @watchers = {} of String => Array(::Channel(ServingStatus))
        @overall_default_status = default_status
      end

      def check_status(service : String) : ServingStatus?
        @mutex.synchronize do
          @statuses[normalize_service_name(service)]?
        end
      end

      def list_statuses : Hash(String, ServingStatus)
        @mutex.synchronize do
          @statuses.dup
        end
      end

      def subscribe(service : String) : {::Channel(ServingStatus), ServingStatus}
        normalized = normalize_service_name(service)

        @mutex.synchronize do
          channel = ::Channel(ServingStatus).new(8)
          watchers = @watchers[normalized]? || begin
            created = [] of ::Channel(ServingStatus)
            @watchers[normalized] = created
            created
          end
          watchers << channel
          {channel, @statuses[normalized]? || ServingStatus::SERVICE_UNKNOWN}
        end
      end

      def unsubscribe(service : String, channel : ::Channel(ServingStatus)) : Nil
        normalized = normalize_service_name(service)
        @mutex.synchronize do
          return unless watchers = @watchers[normalized]?
          watchers.delete(channel)
          @watchers.delete(normalized) if watchers.empty?
        end
      end

      def set_status(service : String, status : ServingStatus) : Nil
        normalized = normalize_service_name(service)
        watchers = [] of ::Channel(ServingStatus)

        changed = @mutex.synchronize do
          previous = @statuses[normalized]?
          next false if previous == status

          @statuses[normalized] = status
          watchers = (@watchers[normalized]? || [] of ::Channel(ServingStatus)).dup
          true
        end

        notify_watchers(watchers, status) if changed
      end

      def clear_status(service : String) : Nil
        normalized = normalize_service_name(service)
        return set_status("", @overall_default_status) if normalized.empty?

        watchers = [] of ::Channel(ServingStatus)
        cleared = @mutex.synchronize do
          removed = @statuses.delete(normalized)
          watchers = (@watchers[normalized]? || [] of ::Channel(ServingStatus)).dup
          !removed.nil?
        end

        notify_watchers(watchers, ServingStatus::SERVICE_UNKNOWN) if cleared
      end

      def set_all_not_serving : Nil
        notifications = [] of {Array(::Channel(ServingStatus)), ServingStatus}

        @mutex.synchronize do
          @statuses.each do |service, current|
            next if current == ServingStatus::NOT_SERVING

            @statuses[service] = ServingStatus::NOT_SERVING
            watchers = (@watchers[service]? || [] of ::Channel(ServingStatus)).dup
            notifications << {watchers, ServingStatus::NOT_SERVING}
          end
        end

        notifications.each do |watchers, status|
          notify_watchers(watchers, status)
        end
      end

      private def notify_watchers(watchers : Array(::Channel(ServingStatus)), status : ServingStatus) : Nil
        watchers.each do |watcher|
          watcher.send(status)
        rescue
        end
      end

      private def normalize_service_name(service : String) : String
        service
      end
    end

    class Reporter
      def initialize(@registry : Registry)
      end

      def set_status(service : String, status : ServingStatus) : self
        @registry.set_status(service, status)
        self
      end

      def clear_status(service : String) : self
        @registry.clear_status(service)
        self
      end

      def set_all_not_serving : self
        @registry.set_all_not_serving
        self
      end

      def shutdown! : self
        set_all_not_serving
      end
    end

    # Built-in standard health checking service.
    # State is owned by Registry/Reporter; Service only serves RPCs.
    class Service < ::Grpc::Health::V1::Health::Service
      SERVICE_FULL_NAME           = ::Grpc::Health::V1::Health::FULL_NAME
      FILE_DESCRIPTOR_PROTO_BYTES = ::Grpc::Health::V1::Health::FILE_DESCRIPTOR_PROTO_BYTES

      getter reporter : Reporter

      def initialize(default_status : ServingStatus = ServingStatus::SERVING)
        @registry = Registry.new(default_status)
        @reporter = Reporter.new(@registry)
      end

      def check(request : ::Grpc::Health::V1::HealthCheckRequest, ctx : GRPC::ServerContext) : ::Grpc::Health::V1::HealthCheckResponse
        _ = ctx
        if status = @registry.check_status(request.service)
          Health.generated_check_response(status)
        else
          raise GRPC::StatusError.new(GRPC::Status.not_found("unknown service #{request.service}"))
        end
      end

      def list(request : ::Grpc::Health::V1::HealthListRequest, ctx : GRPC::ServerContext) : ::Grpc::Health::V1::HealthListResponse
        _ = request
        _ = ctx
        response = ::Grpc::Health::V1::HealthListResponse.new
        @registry.list_statuses.each do |service, status|
          response.statuses[service] = Health.generated_check_response(status)
        end
        response
      end

      def watch(request : ::Grpc::Health::V1::HealthCheckRequest,
                writer : GRPC::ResponseStream(::Grpc::Health::V1::HealthCheckResponse),
                ctx : GRPC::ServerContext) : GRPC::Status
        subscription, current = @registry.subscribe(request.service)
        begin
          writer.send(Health.generated_check_response(current))
          loop do
            select
            when status = subscription.receive
              ctx.check_active!
              writer.send(Health.generated_check_response(status))
            when timeout(100.milliseconds)
              ctx.check_active!
            end
          end
        ensure
          @registry.unsubscribe(request.service, subscription)
        end
      end
    end
  end
end
