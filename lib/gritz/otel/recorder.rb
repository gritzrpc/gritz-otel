# frozen_string_literal: true

module Gritz
  module Otel
    # Preserve pipe deltas while recording worker-local SDK instruments.
    # @api private
    class Recorder < Gritz::Metrics::Recorder
      def initialize(worker:, exporter: nil, timeout: 1.0)
        super()
        @exporter = exporter
        @timeout = timeout
        @attributes = { "worker.index" => worker, "process.pid" => Process.pid }
        @rejected = 0
        return unless exporter

        meter = OpenTelemetry.meter_provider.meter("gritz", version: VERSION)
        @duration = meter.create_histogram("gritz.rpc.server.duration", unit: "s")
        @requests = meter.create_histogram("gritz.rpc.server.requests", unit: "{message}")
        @responses = meter.create_histogram("gritz.rpc.server.responses", unit: "{message}")
        @rejections = meter.create_counter("gritz.rpc.server.rejected", unit: "{request}")
        @gauges = %w[inflight busy_threads capacity rss_bytes pss_bytes].to_h do |name|
          [name, meter.create_gauge("gritz.worker.#{name}")]
        end
        @state = meter.create_gauge("gritz.worker.state")
      end

      def record_rpc(service:, method:, code:, duration:, requests:, responses:)
        super
        return unless @exporter

        attributes = @attributes.merge("rpc.system" => "grpc", "rpc.service" => service, "rpc.method" => method, "rpc.grpc.status_code" => code)
        observe_telemetry do
          @duration.record(duration, attributes:)
          @requests.record(requests, attributes:)
          @responses.record(responses, attributes:)
        end
      end

      def observe_rejected(total)
        super
        observe_telemetry do
          @rejections&.add(total - @rejected, attributes: @attributes)
          @rejected = total
        end
      end

      def observe_worker(status)
        return unless @exporter

        observe_telemetry do
          @gauges.each { |name, gauge| gauge.record(status.fetch(name.to_sym, 0), attributes: @attributes) unless name.end_with?("_bytes") }
          memory.each { |name, value| @gauges.fetch(name).record(value, attributes: @attributes) }
          %w[booting ready draining failed stopped].each do |state|
            @state.record(state == status[:state] ? 1 : 0, attributes: @attributes.merge("state" => state))
          end
          # The official exporter is also a MetricReader. Heartbeats drive bounded exports,
          # avoiding the alpha SDK periodic reader's unbounded shutdown join.
          @exporter.export(@exporter.collect, timeout: @timeout) unless status[:state] == "stopped"
        end
      end

      def close(timeout: @timeout)
        Otel.shutdown(timeout:)
      end

      private

      def observe_telemetry
        yield
      rescue StandardError => e
        OpenTelemetry.logger.warn("Gritz metrics observation failed (#{e.class})")
      end

      def memory
        return {} unless File.readable?("/proc/self/smaps_rollup")

        File.read("/proc/self/smaps_rollup").scan(/^(Rss|Pss):\s+(\d+)\s+kB$/).to_h.transform_keys { |key| "#{key.downcase}_bytes" }
            .transform_values { |value| value.to_i * 1024 }
      rescue SystemCallError
        {}
      end
    end
  end
end
