# frozen_string_literal: true

require "gritz/core"
require "opentelemetry-api"
require_relative "otel/version"
require_relative "otel/tracing"
require_relative "otel/recorder"

module Gritz
  # Optional worker-local OpenTelemetry integration.
  # @api public
  module Otel
    # Configuration-file syntax for this optional integration.
    # @api public
    module ConfigurationDSL
      def opentelemetry(&) = Otel.install(@config, &)
    end

    class << self
      # Registration is safe before fork; SDK providers/exporters are built in the worker hook.
      # @api public
      def install(config, &configure)
        return config if config.middleware.entries.any? { |entry| entry.middleware == ServerTracing }
        raise Gritz::ConfigurationError, "a metrics recorder is already installed" if config.metrics_recorder_factory

        config.middleware.insert_after(Gritz::Middleware::Context, ServerTracing)
        unless Gritz::Client.middleware.entries.any? { |entry| entry.middleware == ClientTracing }
          Gritz::Client.middleware.use(ClientTracing)
        end
        config.add_hook(:on_worker_boot) { bootstrap(config, &configure) }
        config.metrics_recorder_factory = ->(worker:) { Recorder.new(worker:, exporter: @metrics_exporter, timeout: export_timeout(config)) }
        config
      end

      # @api private
      def bootstrap(config, &configure)
        return if @pid == Process.pid

        @metrics_exporter = @tracer_provider = @meter_provider = nil
        return if ENV["OTEL_SDK_DISABLED"] == "true"

        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        if config.metrics_backend == :otlp
          require "opentelemetry-metrics-sdk"
          require "opentelemetry-exporter-otlp-metrics"
          @metrics_exporter = OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter.new
        end
        # SDK.configure swallows boot exceptions; the same official configurator
        # lets an invalid worker configuration reach Gritz's startup failure path.
        sdk = OpenTelemetry::SDK::Configurator.new
        sdk.resource = OpenTelemetry::SDK::Resources::Resource.create("process.pid" => Process.pid, "service.instance.id" => Process.pid.to_s)
        sdk.add_metric_reader(@metrics_exporter) if @metrics_exporter
        # The metrics SDK patches the process-wide configurator once it is loaded.
        # A trace-only worker must not create its default background metric reader.
        if !@metrics_exporter && sdk.respond_to?(:add_metric_reader)
          sdk.add_metric_reader(OpenTelemetry::SDK::Metrics::Export::MetricReader.new)
        end
        configure&.call(sdk)
        sdk.configure
        @tracer_provider = OpenTelemetry.tracer_provider
        @meter_provider = OpenTelemetry.meter_provider if OpenTelemetry.respond_to?(:meter_provider)
        if @metrics_exporter
          { "duration" => Metrics::Recorder::DURATION_BUCKETS, "requests" => Metrics::Recorder::MESSAGE_BUCKETS,
            "responses" => Metrics::Recorder::MESSAGE_BUCKETS }.each do |name, bounds|
            aggregation = OpenTelemetry::SDK::Metrics::Aggregation::ExplicitBucketHistogram.new(boundaries: bounds.select(&:finite?))
            @meter_provider.add_view("gritz.rpc.server.#{name}", aggregation:, type: :histogram, meter_name: "gritz", meter_version: VERSION)
          end
        end
        @pid = Process.pid
      end

      # @api private
      def shutdown(timeout:)
        return unless @pid == Process.pid

        @pid = nil
        deadline = monotonic + timeout
        if @metrics_exporter && timeout.positive?
          shutdown_component { @metrics_exporter.export(@metrics_exporter.collect, timeout: timeout / 2.0) }
        end
        shutdown_component { @tracer_provider&.shutdown(timeout: [deadline - monotonic, 0].max) }
      ensure
        shutdown_component { @meter_provider&.shutdown(timeout: [deadline - monotonic, 0].max) } if deadline
        @metrics_exporter = @tracer_provider = @meter_provider = nil if deadline
      end

      # Keep a slow collector within the worker's heartbeat and shutdown budgets.
      # @api private
      def export_timeout(config) = [1.0, config.status_interval / 2.0, config.shutdown_timeout / 4.0].min
      # @api private
      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      private

      def shutdown_component
        yield
      rescue StandardError => e
        OpenTelemetry.logger.warn("Gritz telemetry shutdown failed (#{e.class})")
      end
    end
  end
end

Gritz::DSL.prepend(Gritz::Otel::ConfigurationDSL)
