# frozen_string_literal: true

module Gritz
  module Otel
    # @api private
    module Tracing
      def self.within(context, kind:, parent:, &block)
        OpenTelemetry::Context.with_current(parent) do
          span = start_span(context, kind)
          code = 0
          begin
            OpenTelemetry::Trace.with_span(span, &block)
          rescue Gritz::Error => e
            code = e.grpc_code
            raise
          rescue StandardError
            code = 13
            raise
          ensure
            code = 1 if code.zero? && context.cancelled?
            finish_span(span, code)
          end
        end
      end

      def self.start_span(context, kind)
        attributes = { "rpc.system" => "grpc", "rpc.service" => context.method.service, "rpc.method" => context.method.name }
        OpenTelemetry.tracer_provider.tracer("gritz", VERSION).start_span(context.method.full_name, kind:, attributes:)
      rescue StandardError => e
        OpenTelemetry.logger.warn("Gritz tracing failed to start (#{e.class})")
        OpenTelemetry::Trace::Span::INVALID
      end

      def self.finish_span(span, code)
        span.set_attribute("rpc.grpc.status_code", code)
        span.status = OpenTelemetry::Trace::Status.error("RPC failed") unless code.zero?
        span.finish
      rescue StandardError => e
        OpenTelemetry.logger.warn("Gritz tracing failed to finish (#{e.class})")
      end
    end

    # Wraps the complete server dispatch, including streaming and error mapping.
    class ServerTracing
      def initialize(app) = @app = app

      def call(context)
        return @app.call(context) if ENV["OTEL_SDK_DISABLED"] == "true"

        carrier = context.metadata.slice("traceparent", "tracestate").transform_values do |value|
          value.is_a?(Array) ? value.join(",") : value
        end
        parent = OpenTelemetry.propagation.extract(carrier, context: OpenTelemetry::Context.empty)
        Tracing.within(context, kind: :server, parent:) do
          context.trace_context = OpenTelemetry::Context.current
          @app.call(context)
        end
      end
    end

    # Capture the caller when the invocation is created, before lazy stream consumption.
    class ClientTracing
      def initialize(app)
        @app = app
        @parent = OpenTelemetry::Context.current
      end

      def call(context)
        return @app.call(context) if ENV["OTEL_SDK_DISABLED"] == "true"

        parent = context.parent&.trace_context
        parent = @parent unless parent.is_a?(OpenTelemetry::Context)
        Tracing.within(context, kind: :client, parent:) do
          context.trace_context = OpenTelemetry::Context.current
          carrier = {}
          OpenTelemetry.propagation.inject(carrier)
          context.metadata.delete("traceparent")
          context.metadata.delete("tracestate")
          context.metadata.merge!(carrier.slice("traceparent", "tracestate"))
          @app.call(context)
        end
      end
    end
  end
end
